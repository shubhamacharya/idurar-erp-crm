import { useState } from 'react';
import { createRoot } from 'react-dom/client';

import Dropdown from './Dropdown';
import './styles.css';

function App() {
  const [vegetable, setVegetable] = useState();
  const [fruit, setFruit] = useState();

  return (
    <div className="App">
      <h1>Hello CodeSandbox</h1>
      <h2>Start editing to see some magic happen!</h2>

      <Dropdown
        placeholder="Select Vegetable"
        value={vegetable}
        onChange={setVegetable}
        options={['Tomato', 'Cucumber', 'Potato']}
      />

      <Dropdown
        placeholder="Select Fruit"
        value={fruit}
        onChange={setFruit}
        options={['Apple', 'Banana', 'Orange', 'Mango']}
      />
    </div>
  );
}

const root = createRoot(document.getElementById('root'));
root.render(<App />);