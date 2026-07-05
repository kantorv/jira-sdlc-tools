**Jira Kanban Board Explained with a Real-World Web SaaS Example**

### What is a Jira Kanban Board?
A **Kanban board** in Jira is a visual workflow management tool. It uses columns to represent stages of work (e.g., Backlog → To Do → In Progress → In Review → Done) and cards that move from left to right as work progresses.

Unlike Scrum (which is time-boxed with sprints), Kanban is **continuous flow** — great for SaaS teams that release features frequently and want to limit work-in-progress (WIP).

### Jira Issue Hierarchy (Epic → Story → Task → Subtask)

Jira has a clear parent-child structure:

| Level      | Purpose                              | Size & Duration          | Who usually creates it     | Example (in a Web SaaS product) |
|------------|--------------------------------------|--------------------------|----------------------------|---------------------------------|
| **Epic**   | Big initiative or feature            | Large (weeks to months)  | Product Manager / Leadership | "User Authentication & Security System" |
| **Story**  | User-focused requirement             | Medium (few days)        | Product Owner / PM         | "As a user, I can sign up with Google" |
| **Task**   | Technical or general work item       | Small (1-3 days)         | Developers / Designers     | "Implement Google OAuth backend" |
| **Subtask**| Breakdown of Story/Task              | Very small (hours)       | Developers                 | "Write unit tests for OAuth callback" |

---

### Practical Example: Building a **Web SaaS Product** (e.g., "Flowly" — a team collaboration & task management SaaS)

Imagine your company is building **Flowly**, a Notion + Trello style SaaS.

#### 1. **Epic** (Big Theme)
- **Epic Name**: *User Authentication & Security Overhaul*
- Description: Everything related to making login/signup secure and smooth.
- Goal: Support multiple auth methods, improve security, and reduce churn from login friction.
- On the Kanban board, Epics are often shown as **large banner cards** or you can filter the board to show only issues under a specific Epic.

#### 2. **User Stories** (under the Epic)
Stories follow the format:  
**"As a [user type], I want [goal] so that [benefit]"**

- Story 1: "As a new user, I can sign up with Google so that I don’t have to create yet another password."
- Story 2: "As a user, I can enable 2FA so that my account is more secure."
- Story 3: "As an admin, I can invite team members via email."

These stories appear as **cards** on the Kanban board.

#### 3. **Tasks** (can be under a Story or standalone)
- Task: "Set up Google OAuth2 configuration in backend"
- Task: "Design new login page UI"
- Task: "Implement rate limiting on login attempts"

#### 4. **Subtasks** (break down a Story or Task)
Under the Google Signup Story:
- Subtask: "Create login button component"
- Subtask: "Handle OAuth callback route"
- Subtask: "Add success/error toast messages"
- Subtask: "Write documentation for the new flow"

---

### How It Looks on a Typical Kanban Board

**Columns** (common setup for SaaS teams):
- **Backlog** → **To Do** → **In Progress** → **In Review** → **Done**

**Card Visualization**:
- **Epic cards** are usually bigger or have a distinct color (e.g., purple).
- **Stories** have a user story icon and are blue.
- **Tasks** are yellow.
- **Subtasks** are often shown inside their parent card (you can expand them).

You can also create a board that shows **only Stories + Tasks** (Epics are managed separately in the Roadmap or Epic panel).

### Typical Workflow in SaaS Development

1. Product team creates **Epics** during quarterly planning.
2. They break Epics into **Stories** and prioritize them in the backlog.
3. Development team breaks Stories into **Tasks** and **Subtasks**.
4. Team pulls work from Backlog → To Do (respecting WIP limits — e.g., max 5 cards in "In Progress").
5. Cards move across the board daily.
6. When a Story is complete (all subtasks + acceptance criteria met), it’s marked Done and the Epic progress updates automatically.

---

### Quick Tips for SaaS Teams Using Jira Kanban

- Use **Components** (Frontend, Backend, Mobile, Infrastructure) and **Labels** (bug, feature, tech-debt).
- Set up **Swimlanes** by Epic or by Assignee to reduce visual clutter.
- Use **Jira Automation** rules (e.g., when all subtasks are done → move Story to Done).
- Link Git branches and pull requests to stories for traceability.

