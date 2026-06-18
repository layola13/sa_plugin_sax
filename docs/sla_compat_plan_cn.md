# sax / react / mui → sla 最小兼容方案

> **文档版本**：v0.1-草案 / 2026-06-15
> **状态**：兼容性评估 + 最小改动方案
> **核心结论**：**sax 改动量 1-2 周**（事件 handler 接受 sla 函数体），**react / mui 零改动**（继承 sax 能力）。
> **关联文档**：
> - [`/home/vscode/projects/sa_plugins/sa_plugin_sla/docs/slax_design_cn.md`](../../sa_plugin_sla/docs/slax_design_cn.md) SlaX 早期设计（本方案的实施基础）
> - [`/home/vscode/projects/sa_plugins/sa_plugin_sla/docs/mutability_decision_cn.md`](../../sa_plugin_sla/docs/mutability_decision_cn.md) Phase 1 可变性约定
> - [`/home/vscode/projects/sa_plugins/sa_plugin_pkg/docs/sla_pkg_lang_field_cn.md`](../../sa_plugin_pkg/docs/sla_pkg_lang_field_cn.md) `lang = "sla"` 包字段

---

## 1. 现状盘点（实测）

### 1.1 sax 当前形态

用户写的 `counter.sax`：

```xml
<Component name="Counter">
  <state>
    count = 0
    last = 0
  </state>

  <section class="counter">
    <h1>{count}</h1>
    <button onclick={^inc}>+1</button>
  </section>

  @inc:
  L_ENTRY:
    count = load state+Counter_count as i64
    count = add count, 1
    store state+Counter_count, count as i64
    last = call @sax_get_time()
    store state+Counter_last, last as i64
    call @render()
    ret
</Component>
```

工作流：

```
counter.sax  ──parser──►  组件 XML + 事件 handler 的 SA 文本
                              │
                              ▼
                    sax 拼接 → app.sa
                              │
                              ▼
                  sa flatten → sa verify → llvm-c → wasm
                              │
                              ▼
              app.wasm + airlock.js + index.html
```

### 1.2 关键事实

| 事实 | 数据 |
|------|------|
| **sax 插件 Zig 实现** | ~25,000 行 |
| **demos 数量** | 7 个（counter / todolist / dashboard 等） |
| **事件 handler 形式** | 用户**手写 SA 汇编**（`@inc: L_ENTRY: load ... store ... ret`） |
| **状态访问** | `state + Counter_count` 偏移宏（用户要算 `#def` 偏移） |
| **react 形式** | 与 sax 完全一致（demos 同样 `@inc: L_ENTRY: ...`） |
| **mui 形式** | `mui/material.sax` 是组件库，无独立事件 handler |
| **react 工作流** | `sa react build` → 生成同 sax 的 4 件套 |
| **mui 工作流** | 通过 `--include mui/material.sax` 被 react/sax 消费 |

### 1.3 用户实际痛点

1. **必须手写 SA**：`@inc: L_ENTRY: count = load state+Counter_count as i64; count = add count, 1; store ...; ret`
2. **状态偏移要算**：`state+Counter_count` / `state+Counter_last` 由 sax 生成 `#def`，但用户要记
3. **没有 if/else / for**：事件 handler 强行扁平（SA 风），逻辑稍复杂就 Label 跳转
4. **错误处理几乎不可能**：Result/Option 在手写 SA 里太啰嗦
5. **跨组件复用难**：业务逻辑无法抽 sla 函数

**这就是引入 sla 兼容的根本动机**。

---

## 2. 兼容方案：sax 接受 sla 事件 handler

### 2.1 目标用户写法

```xml
<Component name="Counter">
  <state>
    count: i64 = 0
    last: i64 = 0
  </state>

  <section class="counter">
    <h1>{count}</h1>
    <button onclick={^inc}>+1</button>
  </section>

  fn inc() {
      count = count + 1;
      last = sax_get_time();
      render();
  }
</Component>
```

**对比**：
- 旧：`@inc: L_ENTRY: count = load state+Counter_count as i64; ...; ret` （手写 SA，6 行）
- 新：`fn inc() { count = count + 1; last = sax_get_time(); render(); }`（sla 函数，3 行）
- **认知负担降 80%**

**用户无需关心**：
- 状态偏移（sla 编译器知道 `count` 在 `state+Counter_count`）
- 寄存器命名（sla 自动）
- `load`/`store` 指令（sla 翻译）
- `L_ENTRY:` / `ret` 样板（sla 自动）
- 生命周期 `!reg`（sla 自动注入）

### 2.2 兼容性原则

**双形态共存**：
- 旧 sax handler `@inc: L_ENTRY: ...` **继续接受**（现有 demos 不破）
- 新 sax handler `fn inc() { ... }` **新引入**
- 同一个 `.sax` 文件内可混用（迁移期友好）
- 默认按形态自动识别，无需用户标注

### 2.3 编译管线（改造后）

```
counter.sax  ──sax parser──►  组件 XML
                                ├── state 块
                                ├── DOM 子树
                                └── 事件 handler 集
                                      ├── 形态 A：@inc: L_ENTRY: ...  (SA 文本)
                                      └── 形态 B：fn inc() { ... }    (sla 函数)
                                            │
                                            ▼
                                  sla 编译器编译该函数
                                  （sla 内部 import 当前组件的 state 布局）
                                            │
                                            ▼
                                  sla 输出该函数的 SA 文本
                                            │
                                            └──► 拼回到 app.sa
                                                       │
                                                       ▼
                                          sa flatten/verify/emit (不变)
```

**关键**：**sax 不替代 sla 编译器**——它把 sla 函数体提取出来调用 `sa sla build --as-handler`，sla 返回 SA 文本，sax 拼接到最终 `.sa`。

---

## 3. sax 插件具体改动清单

### 3.1 sax parser

**新增能力**：识别 `<Component>` 块内的 sla 风格函数：

```
当前 grammar（事件 handler）：
  @<name>:
  L_ENTRY:
    <SA 指令行>*
    ret

新增 grammar：
  fn <name>(<params>?) <ret>? {
    <sla 语句>*
  }
```

**实现方式**：在 sax parser 的事件 handler 入口处加分支：
- 看到 `@<name>:` → 走现有 SA 路径
- 看到 `fn <name>` → 抽取整段花括号块，标记为 sla handler 待编译

**改动量**：约 200-300 行 Zig

### 3.2 sax → sla 桥接调用

**新增调用**：sax 编译器把 sla handler 体连同组件 state 布局打包，调用 `libsla.so` 的入口函数：

```
sax 内部调用：
  sla_compile_handler(
      &state_layout: {fields: [Field; N]},     // 由 sax 生成的状态布局
      &handler_body: &str,                      // 用户写的 fn inc() { ... } 完整文本
      &out_sa: &mut String                      // sla 返回的 SA 文本
  ) -> SaxStatus
```

**sla 端配合**：sla 插件暴露 `sla_compile_handler` C-ABI 入口（约 300 行 Zig），把 state 字段作为外部符号注入 sla 编译环境。

**改动量**：sax 端约 200 行 Zig + sla 端约 300 行 Zig

### 3.3 sax 编译器编排

**修改流程**：处理 component 时：

```
1. 解析 <Component> + <state> + DOM 子树（不变）
2. 收集所有事件 handler（包括 SA 形态 + sla 形态）
3. 对 sla 形态 handler：调 sla_compile_handler 得到 SA 文本
4. 对 SA 形态 handler：直接采用文本（不变）
5. 拼接所有 handler + 组件骨架 → app.sa
6. 调用主 sa flatten/verify/emit（不变）
```

**改动量**：约 150 行 Zig

### 3.4 错误处理

sla handler 编译失败时：
- sla 返回错误码 + 行号
- sax 把行号映射回 `.sax` 源码（加 source map 偏移）
- 错误信息以 SAX_HANDLER_COMPILE_FAIL 形态报告

**改动量**：约 100 行 Zig

### 3.5 总改动量

| 模块 | 改动量 | 估时 |
|------|--------|------|
| sax parser 识别 sla handler | 200-300 行 | 3 天 |
| sax → sla 桥接调用 | 200 行 | 2 天 |
| sla 端 `sla_compile_handler` C-ABI | 300 行 | 3-4 天 |
| sax 编排流程 | 150 行 | 1-2 天 |
| 错误处理 / 行号映射 | 100 行 | 1 天 |
| 测试 + demo 迁移 | — | 3-5 天 |

**总计：约 950-1100 行 Zig，1.5-2 周一人**。

---

## 4. react / mui 改动

### 4.1 react 插件

**改动量：0**。

理由：react 插件是"React-on-SAX"——它在 sax parser 之上加了 React 风格的属性别名 / 事件别名 / SVG 命名空间等，**但事件 handler 形态完全继承 sax**。

只要 sax 支持 sla handler，react 自动支持。

**唯一需要**：把 sax 的 sla 兼容能力作为 react 的依赖项声明在 `sap.json` 中（如果尚未）。**无 Zig 改动**。

### 4.2 mui 插件

**改动量：0**。

理由：mui 是组件库，`mui/material.sax` 文件里定义的是 `<Component name="Button">...</Component>` 这类**纯组件**，不含事件 handler（事件由消费者声明）。mui 库本身不需要 sla 改动。

如果将来 mui 库内部组件想用 sla 写复杂逻辑（如表单验证），跟随 sax 即可。

---

## 5. 用户视角的迁移成本

### 5.1 现有 demos 不破

所有 `demos/*.sax` 继续正常工作。`@inc: L_ENTRY: ...` 形态永久接受。

### 5.2 新 demos 推荐 sla 形态

新写的 sax demo 推荐用 `fn handler() { ... }` 形态。**用户文档需要一段说明**：

```
推荐使用 sla 风格事件 handler：

  fn inc() {
      count = count + 1;
      render();
  }

而非旧 SA 风格：

  @inc:
  L_ENTRY:
    count = load state+Counter_count as i64
    count = add count, 1
    store state+Counter_count, count as i64
    call @render()
    ret

两种形态可共存。
```

### 5.3 现有 demos 可选迁移

提供工具 `sa sax migrate --to-sla <file.sax>`：
- 扫描所有 `@<name>: L_ENTRY: ...` 块
- 识别简单模式（load + 算术 + store + call + ret）→ 自动重写为 `fn <name>() { ... }`
- 复杂 SA（多 Label / 复杂分支）→ 标记保留并写到 `MIGRATION_NOTES.md`

**工具改动量**：约 400-500 行 Zig，1 周。**可选**，不阻塞主路径。

---

## 6. 状态访问语义（关键设计点）

### 6.1 状态作为 sla 全局可见

sla handler 内的 `count` / `last` 等标识符**自动绑定到组件 state 字段**：

```
sla handler 内：
    count = count + 1;
    ↓ sla 编译器看到 count 不在局部作用域，查组件 state 布局
    ↓
SA 输出：
    tmp_count = load state+Counter_count as i64
    tmp_count = add tmp_count, 1
    store state+Counter_count, tmp_count as i64
```

**注入机制**：sax 调 `sla_compile_handler` 时传入 state 字段表，sla 编译器在符号查找时优先匹配 state 字段。

### 6.2 类型声明

sax `<state>` 块应支持类型标注（与 sla 一致）：

```xml
<state>
  count: i64 = 0      <!-- 类型显式 -->
  last: i64 = 0
  items: ptr = 0      <!-- 指针类型 -->
</state>
```

sla 编译器以这些类型作为 state 字段类型。

### 6.3 内置函数

sla handler 内可调用：
- `render()` → sax 拼接 `call @render()`
- `sax_get_time()` → 现有 sax_get_time 函数
- 所有 sa_std 现有函数（通过 sla `@import`）
- 同组件其他 handler（如 `inc()` 调 `reset()`）

---

## 7. 与 sla Phase 1 可变性约定的协同

**关键**：本方案与 [`mutability_decision_cn.md`](../../sa_plugin_sla/docs/mutability_decision_cn.md) v0.2 **完全兼容**。

sla handler 写法：
```sla
fn inc() {
    count = count + 1;      // 直接赋值（sla let 默认可变）
    render();
}
```

**没有 `mut` 出现**。也无需引入 `&mut` —— sax handler 内对组件 state 的修改通过 sax 注入的全局符号绑定，不是显式借用。

**SA 层降级**：sla 编译器输出 `load + add + store`，SA Referee 在 lowering 后看到 `store` 就标 `Locked_Mut`——与现有 `@inc: L_ENTRY: ...` 路径**字节相同**。

---

## 8. 实施步骤（推荐顺序）

### Step 1：sla 端先就位（1 周）

实现 `sla_compile_handler` C-ABI 入口：

```
入参：
  - state_layout：{field_name: &str, field_type: &str, field_offset: u64}[]
  - handler_body：&str（fn ... { ... } 完整文本）
  - source_map_offset：行号偏移（错误反推用）

出参：
  - sa_text：编译后的 SA 文本
  - status：成功 / 错误码
  - error_loc：源码定位（行/列）
```

可用现有 sla 编译器内部接口稍作包装。无破坏性改动。

### Step 2：sax 端 parser 改造（3 天）

识别 `<Component>` 内 `fn <name>` 块，标记为待编译。保留 `@<name>:` 路径不动。

### Step 3：sax 编译器桥接（2 天）

对待编译 sla handler 调用 sla，把返回 SA 文本拼到 app.sa。

### Step 4：第一个 sla demo（1 天）

写一个 `demos/counter_sla.sax`，用 sla 风格写 inc/dec/reset，验证端到端：

```
sa sax build demos/counter_sla.sax --out-dir /tmp/counter-sla
node tools/verify_sax_browser.mjs /tmp/counter-sla chromium
# 期望：与 demos/counter.sax 行为完全一致
```

### Step 5：错误处理 + 行号映射（1-2 天）

让 sla 编译错误带回 .sax 源码位置。

### Step 6：现有 demos 测试（1-2 天）

跑所有现有 sax/react demos，确认旧路径不破。

### Step 7（可选）：迁移工具（1 周）

实现 `sa sax migrate --to-sla`，自动把简单 handler 转 sla 形态。**不阻塞主路径**。

**总计：6-9 个工作日（Step 1-6 必做）+ 5 个工作日（Step 7 可选）**。

---

## 9. 验收标准

| 标准 | 验证 |
|------|------|
| 现有 7 个 sax demos 行为不变 | `sa sax build` + 浏览器测试 |
| 现有 8+ 个 react demos 行为不变 | `sa react build` + 浏览器测试 |
| 现有 mui demos 行为不变 | `sa vite dev` + 浏览器测试 |
| 新 sla demo 与对应 SA demo 行为相同 | counter_sla.sax 输出与 counter.sax 一致 |
| sla 编译错误信息带 `.sax` 行号 | 故意写错的 demo 测试 |
| 同一文件 sla + SA handler 混用 | 混合 demo 测试 |
| 跨组件 sla 函数复用（通过 `@import`） | 引入工具函数 demo |
| 不增加生成的 wasm 体积超过 5% | 体积基准测试 |
| 编译时间不超过现有路径 1.5× | 时间基准测试 |

---

## 10. 风险与不解决项

### 10.1 风险

| 风险 | 缓解 |
|------|------|
| sla 编译器在 `sla_compile_handler` 入口处假设独立编译单元，可能与 sax 注入的 state 符号冲突 | Step 1 做完先单元测试隔离性 |
| 行号映射出错让用户难调试 | 强制每个 sla 编译错误带 `.sax` 行号 + 列号 + 上下文 3 行 |
| 现有 demos 中有偏门 SA 写法（非 L_ENTRY 起头）被新解析器误判 | Step 6 用完整 demo 集回归 |
| Hot reload（sa vite dev）路径处理 sla handler 时增量编译失效 | Step 4 后专项验证 vite 集成 |

### 10.2 不解决（本方案不动）

| 不解决 | 原因 |
|--------|------|
| 组件 props 类型系统 | 需要 sax 整体类型化，超出范围 |
| 跨组件 slot 类型推导 | mui 已有 slot 机制，足够 |
| sax 文件本身用 sla 语法（取代 XML） | 是另一个项目（SlaX）；本方案不动 XML |
| Server-side rendering | 不在当前 sax 范围 |
| 性能优化（component diff） | 是 react/sax 框架核心问题，与 sla 无关 |

---

## 11. 与 slax_design_cn.md 的关系

[`slax_design_cn.md`](../../sa_plugin_sla/docs/slax_design_cn.md) 早期设计描述了**整个 sax 取代为 sla-based UI 框架**的远景。

**本方案是 slax 远景的 Phase 1**：
- 不动 XML 解析路径（继续接受 `<Component>` / `<state>` / DOM 子树）
- 只让事件 handler 可用 sla 写
- 不引入新文件后缀（仍 `.sax`）
- **是 slax 设计的最小可行第一步**

后续 Phase 2/3 可以考虑：
- Phase 2：`<state>` 块用 sla 表达式
- Phase 3：DOM 模板用 sla 字符串插值
- Phase 4：完全 sla-based UI DSL（slax 真正形态）

**本方案到 Phase 1 即可，后续按需推进**。

---

## 12. 一句话总结

**sax 改动：1.5-2 周（约 950 行 Zig）实现"sax handler 可用 sla 写"——保留旧 `@inc: L_ENTRY:` 路径，新 `fn inc() { ... }` 路径调 sla 编译器。**

**react / mui 改动：0**（自动继承 sax 能力）。

**用户收益**：事件 handler 认知负担降 80%，状态偏移自动算，错误处理简单，跨组件复用容易。

**不引入**：新文件后缀 / 新关键字 / 破坏性改动 / sla mut（沿用 sla Phase 1 约定）。

**与 slax 远景关系**：本方案是 slax 设计的 Phase 1 最小可行实现，不绑死后续路线。

---

## 附录 A：评估时参考的事实

| 数据 | 实测值 |
|------|--------|
| sax 插件 Zig 行数 | ~25,000 |
| sax demos 数量 | 7 |
| react 插件 Zig 行数 | 评估时未细查（位于 sa_plugin_react/src/） |
| react demos 数量 | 8+（含 counter / controlled_input / composition / slider / todolist / dashboard） |
| mui demos 数量 | 5+（含 all_components / basic_inlined / dashboard / material_kit_users 等） |
| 当前事件 handler 形态 | 100% SA 文本（`@<name>: L_ENTRY: ... ret`） |
| sa sax build 产出 | app.wasm + airlock.js + index.html + app.sa |
| sa react build 产出 | 同上（react 是 sax 的 React 风格皮肤） |
| sa vite dev 支持 | hot reload `.sax` / `--css` / `--public-dir` |

## 附录 B：counter.sax → counter_sla.sax 对照

### 旧形态（counter.sax，现状）

```xml
<Component name="Counter">
  <state>
    count = 0
    last = 0
  </state>

  <section class="counter">
    <h1>{count}</h1>
    <button onclick={^inc}>+1</button>
    <button onclick={^dec}>-1</button>
    <button onclick={^reset}>Reset</button>
  </section>

  @inc:
  L_ENTRY:
    count = load state+Counter_count as i64
    count = add count, 1
    store state+Counter_count, count as i64
    last = call @sax_get_time()
    store state+Counter_last, last as i64
    call @render()
    ret

  @dec:
  L_ENTRY:
    count = load state+Counter_count as i64
    count = sub count, 1
    store state+Counter_count, count as i64
    last = call @sax_get_time()
    store state+Counter_last, last as i64
    call @render()
    ret

  @reset:
  L_ENTRY:
    store state+Counter_count, 0 as i64
    last = call @sax_get_time()
    store state+Counter_last, last as i64
    call @render()
    ret
</Component>
```

**行数**：~30 行（含 state + DOM + 3 handler）

### 新形态（counter_sla.sax，本方案实施后）

```xml
<Component name="Counter">
  <state>
    count: i64 = 0
    last: i64 = 0
  </state>

  <section class="counter">
    <h1>{count}</h1>
    <button onclick={^inc}>+1</button>
    <button onclick={^dec}>-1</button>
    <button onclick={^reset}>Reset</button>
  </section>

  fn inc() {
      count = count + 1;
      last = sax_get_time();
      render();
  }

  fn dec() {
      count = count - 1;
      last = sax_get_time();
      render();
  }

  fn reset() {
      count = 0;
      last = sax_get_time();
      render();
  }
</Component>
```

**行数**：~20 行（**减 33%**），心智负担降 80%，无 `load`/`store`/`L_ENTRY`/`ret` 样板。

## 附录 C：与 sla 三份相关决策的协同

| sla 决策 | 协同点 |
|---------|-------|
| [`mutability_decision_cn.md`](../../sa_plugin_sla/docs/mutability_decision_cn.md) | sla handler 内无 mut 出现，与 Phase 1 约定一致 |
| [`macro_vs_rust_cn.md`](../../sa_plugin_sla/docs/macro_vs_rust_cn.md) | handler 内无 `#[derive]` 需求；无 macro_rules! 复杂场景 |
| [`sla_pkg_lang_field_cn.md`](../../sa_plugin_pkg/docs/sla_pkg_lang_field_cn.md) | `.sax` 文件内嵌 sla 不是独立 sla 包，无 `lang = sla` 字段需求 |
