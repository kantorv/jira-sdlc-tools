### 1. Basic Structure

Every Mermaid diagram starts the same way:

```text
    ```mermaid
    [diagram type] [direction]
        [content]
    ```
```

### 2. Main Diagram Types & Syntax Variations

Here are the most useful ones with syntax examples:

#### **Flowchart** (most popular)

```mermaid
flowchart TD
    A[Start] --> B{Decision?}
    B -->|Yes| C[Action 1]
    B -->|No| D[Action 2]
    C --> E[End]
    D --> E
```

**Direction variations**:
- `TD` or `TB` → Top to Bottom
- `BT` → Bottom to Top
- `LR` → Left to Right
- `RL` → Right to Left

**Node shape variations**:
- `A[Text]` → Rectangle
- `A(Text)` → Rounded
- `A((Text))` → Circle
- `A[[Text]]` → Stadium
- `A[(Text)]` → Cylinder
- `A{{Text}}` → Hexagon
- `A[/Text/]` → Parallelogram

#### **Sequence Diagram**

```mermaid
sequenceDiagram
    participant User
    participant System
    participant Database
    
    User->>System: Login request
    System->>Database: Validate credentials
    Database-->>System: Credentials valid
    System-->>User: Welcome!
    
    Note over User,System: Authentication flow
```

#### **Class Diagram**

```mermaid
classDiagram
    class Animal {
        +String name
        +eat()
    }
    class Dog {
        +bark()
    }
    Animal <|-- Dog
```

#### **Other Popular Types**

**Mindmap**
```mermaid
mindmap
  root((Mermaid))
    Features
      Text-based
      Live preview
    Use Cases
      Documentation
      Architecture
```

**Timeline**
```mermaid
timeline
    title Project Timeline
    section Planning
        Requirements : done
    section Development
        Coding : active
        Testing
```

**Gantt Chart**
```mermaid
gantt
    title Project Schedule
    dateFormat  YYYY-MM-DD
    section Planning
    Research           :a1, 2026-01-01, 30d
```

**Entity Relationship (ER)**
```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
```

**State Diagram**
```mermaid
stateDiagram-v2
    [*] --> Still
    Still --> Moving : Accelerate
    Moving --> Still : Brake
```

**Pie Chart**
```mermaid
pie title Distribution
    "Apples" : 45
    "Bananas" : 30
    "Oranges" : 25
```

### 3. Advanced Syntax Features

- **Comments**: `%% This is a comment`
- **Styling**:
  ```mermaid
  flowchart TD
      A[Start] --> B[Process]
      style A fill:#f9f,stroke:#333,stroke-width:4px
      classDef blue fill:#2196f3,stroke:#fff
      class B blue
  ```
- **Subgraphs** (grouping nodes):
  ```mermaid
  flowchart TD
      subgraph One
          A --> B
      end
  ```
- **Click interactions**:
  ```mermaid
  flowchart TD
      A[Click me] --> B[Result]
      click A href "https://example.com"
  ```

### 4. Configuration Options

You can add configuration at the top:

```mermaid
---
config:
  theme: base
  flowchart:
    curve: basis
---
flowchart TD
    A --> B
```

Common themes: `default`, `base`, `dark`, `forest`, `neutral`.