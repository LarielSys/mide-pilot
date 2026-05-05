# MOSS Architecture Workflow for CustomIDE

## Purpose
This document explains:
1. What MOSS is used for in this repo.
2. How architecture is fed into MOSS format.
3. How to run the compiler.
4. How visualization is generated.
5. The actual MOSS source code for the current VS-style IDE architecture.

---

## What MOSS Is (In This Project)
MOSS is the canonical architecture language used to define system structure and execution flow before implementation.

In this workflow, MOSS is used as:
1. Architecture source of truth.
2. Validation input for compiler checks.
3. Diagram source for interactive visualization.
4. Drift-control contract for tasks and reviews.

---

## End-to-End Pipeline

### Step 1: Describe architecture in plain design terms
Start with a human architecture draft that answers:
1. Components: what exists.
2. Dependencies: who talks to who.
3. Interfaces: protocol and endpoints.
4. Actions: key operational flows.
5. Constraints: non-negotiable rules.

For this IDE:
1. Files left, editor center, chat right.
2. Clipboard popup for no-MTASK fast paste.
3. Image paste into chat.
4. Local git workflow without GitHub dependency.
5. Model routing to GPT key or Ubuntu Ollama.
6. Worker profile switching for Worker 1 and Worker 2.

### Step 2: Convert architecture draft into MOSS source
Map the design into MOSS sections:
1. systems
2. dependencies
3. interfaces
4. actions
5. runtime_constraints

MOSS internal control headers:
1. @MOSS:<manual_name>
2. @R:<repo_relative_root>

### Step 3: Save the MOSS file
Current file path:
MIDE/pilot_v1/specs/customide_vs_worker_bridge/architecture.moss

### Step 4: Compile with MOSS compiler
Compiler location:
C:/Users/marco/OneDrive/Desktop/MOSS/moss.py

Example compile command (PowerShell):
~~~powershell
python -c "import sys; sys.path.append(r'C:\Users\marco\OneDrive\Desktop\MOSS'); import moss; result = moss.load(r'C:\AI Assistant\MIDE\pilot_v1\specs\customide_vs_worker_bridge\architecture.moss'); print('Success:', result is not None); print({k: len(v) if isinstance(v, (list, dict)) else v for k, v in result.items()})"
~~~

Expected output shape:
1. Success: True
2. systems count
3. dependencies count
4. interfaces count
5. actions count
6. runtime_constraints count
7. _moss_manual and _moss_r

### Step 5: Generate visualization
Visualization artifact path:
MIDE/pilot_v1/gui/customide_vs_worker_bridge_visualization.html

Uniform visualization rules (enforced):
1. Left pane: MOSS source.
2. Center pane: architecture diagram.
3. Right pane: component details.
4. Hovering a diagram node highlights corresponding source lines on the left.
5. Hovering a diagram node updates the right details pane.

Local run example:
~~~powershell
cd C:\AI Assistant\MIDE\pilot_v1\gui
python -m http.server 5591
~~~

Open:
http://127.0.0.1:5591/customide_vs_worker_bridge_visualization.html

---

## How Architecture Is Fed Into MOSS (Conversion Pattern)

### Human architecture input (example)
1. IDE shell has three columns.
2. Chat can route to GPT or Ubuntu Ollama.
3. Local git should not require GitHub.
4. Images can be pasted into chat.

### Converted MOSS structure
1. systems entries define each component and role.
2. dependencies lines define edges.
3. interfaces define protocol and routes.
4. actions define user/system operational flows.
5. runtime_constraints lock mandatory behavior.

This conversion happens before compile. Compile only validates and structures the MOSS source; it does not invent architecture.

---

## Actual MOSS Code (Current IDE Architecture)

~~~text
@MOSS:CustomIDE_VSStyle_WorkerBridge_v1
@R:~/mide-pilot/pilot_v1/specs/customide_vs_worker_bridge/

systems:

  IDE_Shell:
    role: VS-like local IDE shell with 3-column layout
    runtime: windows-main
    layout: files_left, editor_center, chat_right
    theme: olegreen_cockpit
    depends_on: File_Tree_Service, Editor_Canvas, Chat_Panel
    outputs: developer_workspace

  File_Tree_Service:
    role: browse and manage local project files
    runtime: windows-main
    capabilities: open, rename, move, delete, search
    depends_on: Workspace_FS_Boundary

  Editor_Canvas:
    role: Monaco-based code editing surface
    runtime: windows-main
    features: tabs, syntax_highlight, diff_view, terminal_panel
    depends_on: Workspace_FS_Boundary, Local_Git_Service

  Chat_Panel:
    role: right-side assistant chat with provider routing
    runtime: windows-main
    features: model_switch, context_attach, history
    depends_on: Chat_Broker, Clipboard_Pad, Image_Paste_Channel

  Clipboard_Pad:
    role: popup message window for fast copy/paste when MTASK is not needed
    runtime: windows-main
    features: large_text_area, quick_copy, quick_insert, session_snippets
    depends_on: Chat_Panel

  Image_Paste_Channel:
    role: receive clipboard image pastes and attach to chat turns
    runtime: windows-main
    formats: png, jpg, webp
    storage: local_session_cache
    depends_on: Chat_Broker

  Chat_Broker:
    role: route chat requests to selected model provider
    runtime: windows-main
    providers: GPT_API, Ollama_Ubuntu
    policy: per_message_or_session_route
    depends_on: GPT_API_Gateway, Ollama_Ubuntu_Gateway

  GPT_API_Gateway:
    role: use user ai key for GPT chat/completions
    runtime: windows-main
    auth: local_encrypted_key_store
    outputs: model_response_stream

  Ollama_Ubuntu_Gateway:
    role: proxy coding/chat requests to ubuntu ollama
    runtime: windows-main
    transport: ssh_tunnel_or_http
    target: ubuntu-worker-02
    outputs: model_response_stream

  Local_Git_Service:
    role: local-only git operations without github dependency
    runtime: windows-main
    remotes: local_path_or_worker_ssh_remote
    constraints: no_forced_github_remote
    capabilities: init, add, commit, branch, diff, push_pull_local

  Workspace_FS_Boundary:
    role: enforce project root safety for file operations
    runtime: windows-main
    base_path: C:/AI Assistant/workspaces
    constraints: no_path_escape

  Worker_Profile_Manager:
    role: switch between worker1 and worker2 connection profiles
    runtime: windows-main
    stores: host, key_path, ollama_endpoint, repo_remote
    depends_on: Ollama_Ubuntu_Gateway, Local_Git_Service

dependencies:
  - IDE_Shell -> File_Tree_Service
  - IDE_Shell -> Editor_Canvas
  - IDE_Shell -> Chat_Panel
  - Editor_Canvas -> Workspace_FS_Boundary
  - Editor_Canvas -> Local_Git_Service
  - Chat_Panel -> Clipboard_Pad
  - Chat_Panel -> Image_Paste_Channel
  - Chat_Panel -> Chat_Broker
  - Chat_Broker -> GPT_API_Gateway
  - Chat_Broker -> Ollama_Ubuntu_Gateway
  - Ollama_Ubuntu_Gateway -> Worker_Profile_Manager
  - Local_Git_Service -> Worker_Profile_Manager

interfaces:

  IDE_UI_Contract:
    protocol: internal_ui_events
    panes: files_left, editor_center, chat_right
    popup: clipboard_pad_modal

  Chat_Broker_API:
    protocol: HTTP_JSON_stream
    routes:
      - POST /api/chat/send
      - POST /api/chat/send-with-image
      - POST /api/chat/provider/select

  Local_Git_API:
    protocol: local_process_contract
    routes:
      - POST /api/git/init
      - POST /api/git/status
      - POST /api/git/commit
      - POST /api/git/push-local
      - POST /api/git/pull-local

  Ollama_Ubuntu_API:
    protocol: HTTP_JSON_stream
    routes:
      - POST /api/ollama/chat
      - POST /api/ollama/generate
      - GET /api/ollama/health

  Image_Paste_API:
    protocol: multipart_http
    routes:
      - POST /api/chat/attachment/image

actions:

  Open_Project_Workspace:
    trigger: user chooses local folder
    flow:
      - IDE_Shell loads project inside Workspace_FS_Boundary
      - File_Tree_Service indexes files
      - Editor_Canvas opens last session tabs

  Fast_Paste_No_MTASK:
    trigger: user opens Clipboard_Pad popup
    flow:
      - user pastes code_or_logs
      - Chat_Panel references pasted snippet
      - assistant responds without mtask overhead

  Chat_With_Selected_Model:
    trigger: user sends chat message
    flow:
      - Chat_Broker reads provider selection
      - request routed to GPT_API_Gateway or Ollama_Ubuntu_Gateway
      - streamed response returned to Chat_Panel

  Paste_Image_To_Chat:
    trigger: user presses Ctrl+V with image in clipboard
    flow:
      - Image_Paste_Channel captures image
      - attachment stored in local session cache
      - Chat_Broker sends image+prompt to selected provider

  Local_Git_Workflow:
    trigger: user performs source control action
    flow:
      - Local_Git_Service executes local git commands
      - optional push_pull to worker ssh remote
      - no github requirement

runtime_constraints:
  - layout_must_match: files_left_editor_center_chat_right
  - local_git_only: true
  - github_dependency: false
  - image_paste_required: true
  - support_worker2_first_class: true
  - visual_theme: olegreen_cockpit
~~~

---

## Internal Instructions Summary (Inside MOSS Source)
These are the internal guidance instructions encoded directly in the MOSS file:

1. Layout instruction:
files_left_editor_center_chat_right is mandatory.

2. Source control instruction:
local_git_only true and github_dependency false.

3. Input modality instruction:
image_paste_required true.

4. Multi-worker instruction:
support_worker2_first_class true.

5. Visual instruction:
visual_theme olegreen_cockpit.

These constraints drive both implementation and review decisions.
