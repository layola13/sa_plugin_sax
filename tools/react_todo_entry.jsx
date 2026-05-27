import React, { useState } from "react";
import { createRoot } from "react-dom/client";

function TodoApp() {
  const [items, setItems] = useState([]);
  const [value, setValue] = useState("");

  const addItem = () => {
    const next = value.trim();
    if (!next || items.length >= 3) return;
    setItems((current) => [...current, next]);
    setValue("");
  };

  const removeLast = () => {
    setItems((current) => current.slice(0, -1));
  };

  return (
    <section className="todo-list">
      <h1>TodoList</h1>
      <input
        className="field"
        placeholder="New item"
        value={value}
        onChange={(event) => setValue(event.target.value)}
      />
      <button onClick={addItem}>Add</button>
      <button onClick={removeLast}>Delete last</button>
      <p>Items: {items.length}</p>
      <ul>
        {[0, 1, 2].map((index) => (
          <li key={index}>{items[index] ?? ""}</li>
        ))}
      </ul>
    </section>
  );
}

const rootNode = document.getElementById("app");
if (!rootNode) throw new Error("missing #app root");
createRoot(rootNode).render(<TodoApp />);
