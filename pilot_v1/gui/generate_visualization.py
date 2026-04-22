"""
generate_visualization.py
Reads architecture.moss, compiles it via MOSSCompiler, and outputs an
interactive HTML visualization of the CustomIDE architecture.
"""

import sys
import re
import json
from pathlib import Path

# ── Load MOSSCompiler ────────────────────────────────────────────────────────
MOSS_PY = Path(r"C:\Users\marco\OneDrive\Desktop\MOSS\moss.py")
sys.path.insert(0, str(MOSS_PY.parent))

from moss import MOSSCompiler, MOSSError

# ── Paths ────────────────────────────────────────────────────────────────────
MOSS_FILE   = Path(r"C:\AI Assistant\MIDE\pilot_v1\specs\customide_ollama\architecture.moss")
OUTPUT_HTML = Path(r"C:\AI Assistant\MIDE\pilot_v1\gui\customide_visualization.html")

# ── Parse architecture.moss ─────────────────────────────────────────────────
# The file uses [R:…], [ACT:…], [INT:…] bracket-section format (no @MOSS: header).
# We pre-process it into MOSS-compatible key:value blocks so the compiler can
# validate individual sections, then build our own data dict for the visualiser.

raw_text = MOSS_FILE.read_text(encoding="utf-8")
raw_lines = raw_text.splitlines()

# --------------------------------------------------------------------------
# Custom section parser  (handles the bracket-header format)
# --------------------------------------------------------------------------
def parse_architecture_moss(lines):
    """
    Returns dict with keys:
        resources: {name: {props}}
        actions:   {name: {props}}
        interfaces:{name: {props}}
        system:    {props}
    """
    data = {"resources": {}, "actions": {}, "interfaces": {}, "system": {}}

    section_pat = re.compile(r'^\[([A-Z]+):?([^\]]*)\]$')
    system_pat  = re.compile(r'^\[SYSTEM\]$')
    kv_pat      = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_ ]*)\s*:\s*(.*)$')

    current_section = None
    current_type    = None
    current_name    = None
    current_dict    = None
    indent_stack    = []   # [(indent, dict_ref)]

    def store_kv(key, value, indent):
        nonlocal current_dict
        # Walk up indent stack to correct parent
        while indent_stack and indent_stack[-1][0] >= indent:
            indent_stack.pop()
        parent = indent_stack[-1][1] if indent_stack else current_dict
        if parent is None:
            return
        if isinstance(parent, dict):
            parent[key.strip()] = value.strip()
            # Push new context
            indent_stack.append((indent, parent.setdefault(key.strip(), {})))
            parent[key.strip()] = value.strip()   # keep scalar unless nested follows

    for raw in lines:
        # Skip pure comment lines
        comment_only = raw.strip().startswith("#")
        if comment_only:
            continue

        # Strip inline comment
        code = raw.split("#")[0].rstrip()
        if not code.strip():
            continue

        # Separator
        if code.strip() == "---":
            indent_stack.clear()
            continue

        # Section header
        sm = system_pat.match(code.strip())
        if sm:
            current_type = "system"
            current_name = "SYSTEM"
            current_dict = data["system"]
            indent_stack.clear()
            continue

        m = section_pat.match(code.strip())
        if m:
            stype = m.group(1)
            sname = m.group(2).strip() if m.group(2) else ""
            if stype == "R":
                current_type = "resources"
                current_name = sname
                data["resources"][sname] = {}
                current_dict = data["resources"][sname]
            elif stype == "ACT":
                current_type = "actions"
                current_name = sname
                data["actions"][sname] = {}
                current_dict = data["actions"][sname]
            elif stype == "INT":
                current_type = "interfaces"
                current_name = sname
                data["interfaces"][sname] = {}
                current_dict = data["interfaces"][sname]
            else:
                current_type = None
                current_dict = None
            indent_stack.clear()
            continue

        if current_dict is None:
            continue

        # Key:value lines
        kv = kv_pat.match(raw)
        if kv:
            indent = len(kv.group(1))
            key    = kv.group(2).strip()
            value  = kv.group(3).strip()

            # Maintain indent hierarchy for nested props
            while indent_stack and indent_stack[-1][0] >= indent:
                indent_stack.pop()

            if indent_stack:
                parent = indent_stack[-1][1]
            else:
                parent = current_dict

            if isinstance(parent, dict):
                if value:
                    parent[key] = value
                else:
                    parent[key] = {}
                    indent_stack.append((indent, parent[key]))
            continue

        # List items
        li_m = re.match(r'^(\s+)-\s+(.*)$', raw)
        if li_m and current_dict is not None:
            indent = len(li_m.group(1))
            item   = li_m.group(2).strip()
            # Find parent list context
            while indent_stack and indent_stack[-1][0] >= indent:
                indent_stack.pop()
            parent = indent_stack[-1][1] if indent_stack else current_dict
            if isinstance(parent, dict):
                # Store as numbered entries
                idx = sum(1 for k in parent if k.startswith("_item"))
                parent[f"_item{idx}"] = item

    return data


arch = parse_architecture_moss(raw_lines)

# ── Also attempt MOSSCompiler on a preprocessed version ─────────────────────
# (demonstrates the API; the compiler needs @MOSS: header)
compiler = MOSSCompiler()
moss_compiled = None
try:
    # Insert the required header into a temp string and write to temp file
    import tempfile, os
    tmp_lines = [f"@MOSS: CustomIDE_Architecture\n"] + [l + "\n" for l in raw_lines]
    with tempfile.NamedTemporaryFile(mode="w", suffix=".moss",
                                     delete=False, encoding="utf-8") as tf:
        tf.writelines(tmp_lines)
        tmp_path = tf.name
    moss_compiled = compiler.load(tmp_path)
    os.unlink(tmp_path)
    print(f"[MOSSCompiler] Loaded OK — manual: {moss_compiled.get('_moss_manual')}")
except MOSSError as e:
    print(f"[MOSSCompiler] Note: {e}")
except Exception as e:
    print(f"[MOSSCompiler] Unexpected: {e}")

# ── Summarise what we parsed ──────────────────────────────────────────────────
resources   = arch["resources"]
actions     = arch["actions"]
interfaces  = arch["interfaces"]
system_info = arch["system"]

print(f"Parsed: {len(resources)} resources, {len(actions)} actions, {len(interfaces)} interfaces")

# ── Main blocks (the 5 required + supporting) ────────────────────────────────
MAIN_BLOCKS = [
    "IDE_Frontend_Windows",
    "IDE_Backend_Windows",
    "Ollama_Local_Server",
    "SSH_Worker1_Bridge",
    "Script_Execution_Engine",
]

# ── Build MOSS code lines for left panel (syntax-coloured) ───────────────────
def build_moss_code_lines(raw_lines):
    """Returns list of {text, type} for the left panel."""
    result = []
    section_pat = re.compile(r'^\[([A-Z]+):?([^\]]*)\]$')
    for raw in raw_lines:
        stripped = raw.strip()
        if stripped.startswith("#"):
            result.append({"text": stripped, "type": "comment"})
        elif stripped == "---":
            result.append({"text": "---", "type": "separator"})
        elif section_pat.match(stripped):
            result.append({"text": stripped, "type": "section"})
        elif ":" in stripped and not stripped.startswith("-"):
            parts = stripped.split(":", 1)
            result.append({"text": stripped, "type": "kv",
                           "k": parts[0].strip(), "v": parts[1].strip()})
        elif stripped.startswith("- "):
            result.append({"text": stripped, "type": "listitem"})
        elif stripped == "":
            result.append({"text": "", "type": "blank"})
        else:
            result.append({"text": stripped, "type": "plain"})
    return result

code_lines = build_moss_code_lines(raw_lines)

# ── Build component details dict for right panel ─────────────────────────────
def safe(d, key):
    v = d.get(key, "")
    return str(v) if v else ""

component_details = {}
for name, props in resources.items():
    component_details[name] = {
        "name": name,
        "type": safe(props, "Type"),
        "location": safe(props, "Location"),
        "description": safe(props, "Description"),
        "language": safe(props, "Language"),
        "port": safe(props, "Port"),
    }

# Actions summary
action_summary = {}
for name, props in actions.items():
    action_summary[name] = {
        "name": name,
        "trigger": safe(props, "Trigger"),
    }

# Interface summary
interface_summary = {}
for name, props in interfaces.items():
    interface_summary[name] = {
        "name": name,
        "protocol": safe(props, "Protocol"),
        "port": safe(props, "Port"),
    }

# ── Connections (edges) for the diagram ──────────────────────────────────────
# Derived from Dependencies / Accessed_By fields
edges = [
    {"from": "IDE_Frontend_Windows",  "to": "IDE_Backend_Windows",    "label": "HTTP REST :5555"},
    {"from": "IDE_Backend_Windows",   "to": "Ollama_Local_Server",     "label": "POST /api/generate"},
    {"from": "IDE_Backend_Windows",   "to": "Script_Execution_Engine", "label": "execute()"},
    {"from": "IDE_Backend_Windows",   "to": "SSH_Worker1_Bridge",      "label": "remote exec"},
    {"from": "SSH_Worker1_Bridge",    "to": "Worker_1_Ubuntu_System",  "label": "SSH :22"},
    {"from": "IDE_Frontend_Windows",  "to": "Remote_IDE_View",         "label": "right pane"},
    {"from": "Remote_IDE_View",       "to": "SSH_Worker1_Bridge",      "label": "data source"},
    {"from": "Script_Execution_Engine","to": "SSH_Worker1_Bridge",     "label": "execute_remote()"},
    {"from": "Ollama_Version_Coordinator","to": "Ollama_Local_Server", "label": "version spec"},
    {"from": "IDE_Backend_Windows",   "to": "Git_Integration",         "label": "git ops"},
    {"from": "IDE_Backend_Windows",   "to": "File_System_Local",       "label": "read/write"},
]

# ── Serialise data for embedding in HTML ─────────────────────────────────────
js_code_lines    = json.dumps(code_lines,         ensure_ascii=False)
js_comp_details  = json.dumps(component_details,  ensure_ascii=False)
js_act_summary   = json.dumps(action_summary,     ensure_ascii=False)
js_int_summary   = json.dumps(interface_summary,  ensure_ascii=False)
js_edges         = json.dumps(edges,              ensure_ascii=False)
js_resources     = json.dumps(list(resources.keys()), ensure_ascii=False)
sys_name         = system_info.get("Name", "CustomIDE_DualPane_SharedOllama")

# ── Generate HTML ─────────────────────────────────────────────────────────────
html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CustomIDE Architecture — MOSS Visualization</title>
  <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;500;600;700;900&family=Rajdhani:wght@300;400;500;600;700&family=Share+Tech+Mono&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{
      --bg-deep:    #020810;
      --bg-dark:    #0a1628;
      --bg-card:    rgba(10, 22, 40, 0.85);
      --cyan:       #00d4ff;
      --cyan-dim:   #00d4ff66;
      --cyan-glow:  0 0 15px #00d4ff44, 0 0 30px #00d4ff22;
      --amber:      #ffaa00;
      --amber-dim:  #ffaa0066;
      --green:      #44ff88;
      --purple:     #bb88ff;
      --red:        #ff6655;
      --text:       #c8dce8;
      --text-dim:   #7a99b5;
      --border:     rgba(0,212,255,0.15);
      --font-head:  'Orbitron', sans-serif;
      --font-body:  'Rajdhani', sans-serif;
      --font-mono:  'Share Tech Mono', monospace;
    }}
    html {{ scroll-behavior: smooth; }}
    body {{
      font-family: var(--font-body);
      color: var(--text);
      background: var(--bg-deep);
      min-height: 100vh;
      overflow: hidden;
    }}

    /* ── TOP BAR ── */
    .top-bar {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 24px;
      border-bottom: 1px solid var(--border);
      background: var(--bg-dark);
      flex-shrink: 0;
    }}
    .top-bar .logo {{
      font-family: var(--font-head);
      font-size: 13px;
      color: var(--cyan);
      letter-spacing: 2px;
    }}
    .top-bar .logo span {{ color: var(--amber); }}
    .top-bar .subtitle {{
      font-family: var(--font-mono);
      font-size: 11px;
      color: var(--text-dim);
    }}
    .top-bar .badge {{
      display: inline-block;
      background: rgba(0,212,255,0.12);
      border: 1px solid var(--cyan-dim);
      border-radius: 3px;
      padding: 2px 10px;
      font-family: var(--font-mono);
      font-size: 10px;
      color: var(--cyan);
    }}
    .dot {{ display: inline-block; width: 7px; height: 7px; border-radius: 50%;
            background: #22c55e; margin-right: 6px; animation: pulse-dot 2s infinite; }}
    @keyframes pulse-dot {{ 0%,100% {{ opacity:1; }} 50% {{ opacity:0.4; }} }}

    /* ── THREE-PANEL LAYOUT ── */
    .panels {{
      display: grid;
      grid-template-columns: 1fr 1.5fr 1fr;
      height: calc(100vh - 53px);
    }}
    .panel {{
      display: flex;
      flex-direction: column;
      border-right: 1px solid var(--border);
      overflow: hidden;
    }}
    .panel:last-child {{ border-right: none; }}
    .panel-header {{
      font-family: var(--font-head);
      font-size: 10px;
      letter-spacing: 2px;
      text-transform: uppercase;
      color: var(--cyan);
      padding: 11px 18px;
      border-bottom: 1px solid var(--border);
      background: rgba(0,212,255,0.03);
      display: flex;
      align-items: center;
      gap: 8px;
      flex-shrink: 0;
    }}
    .panel-header .tag {{
      background: var(--cyan);
      color: var(--bg-deep);
      padding: 2px 7px;
      border-radius: 3px;
      font-size: 9px;
      font-family: var(--font-mono);
    }}
    .panel-header .tag.amber {{ background: var(--amber); }}
    .panel-header .tag.green {{ background: var(--green); }}
    .panel-body {{ flex: 1; overflow-y: auto; padding: 14px 18px; }}

    /* ── LEFT: MOSS CODE ── */
    .moss-code {{
      font-family: var(--font-mono);
      font-size: 11.5px;
      line-height: 1.65;
      white-space: pre;
    }}
    .moss-line {{
      display: block;
      padding: 1px 6px;
      border-left: 2px solid transparent;
      transition: all 0.2s;
      cursor: default;
    }}
    .moss-line:hover {{ background: rgba(0,212,255,0.04); border-left-color: var(--cyan-dim); }}
    .moss-line.highlight {{ color: var(--cyan); border-left-color: var(--cyan);
                            background: rgba(0,212,255,0.08); }}
    .t-comment  {{ color: #3a5a6a; }}
    .t-section  {{ color: var(--cyan); font-weight: 600; }}
    .t-key      {{ color: var(--amber); }}
    .t-val      {{ color: var(--text); }}
    .t-listitem {{ color: var(--text-dim); }}
    .t-separator{{ color: #2a4a5a; }}
    .t-blank    {{ }}

    /* ── CENTER: BLOCK DIAGRAM ── */
    #diagramSvg {{
      width: 100%;
      height: 100%;
      min-height: 520px;
    }}
    .block-rect {{
      rx: 8;
      ry: 8;
      fill: rgba(10,22,40,0.9);
      stroke: rgba(0,212,255,0.3);
      stroke-width: 1.5;
      transition: all 0.25s;
      cursor: pointer;
    }}
    .block-rect.hovered  {{ stroke: #00d4ff; stroke-width: 2.5;
                            filter: drop-shadow(0 0 8px #00d4ff66); }}
    .block-rect.active   {{ stroke: #00d4ff; stroke-width: 2.5;
                            filter: drop-shadow(0 0 12px #00d4ff88); }}
    .block-rect.ollama   {{ stroke: rgba(255,170,0,0.5); }}
    .block-rect.ollama.hovered {{ stroke: var(--amber);
                                  filter: drop-shadow(0 0 8px #ffaa0066); }}
    .block-rect.worker   {{ stroke: rgba(68,255,136,0.4); }}
    .block-rect.worker.hovered {{ stroke: var(--green);
                                  filter: drop-shadow(0 0 8px #44ff8866); }}
    .block-rect.support  {{ stroke: rgba(187,136,255,0.35); }}
    .block-rect.support.hovered {{ stroke: var(--purple);
                                   filter: drop-shadow(0 0 8px #bb88ff66); }}
    .block-label {{ font-family: 'Share Tech Mono', monospace; font-size: 9px;
                    fill: #7a99b5; }}
    .block-name  {{ font-family: 'Rajdhani', sans-serif; font-size: 12px;
                    font-weight: 600; fill: #c8dce8; }}
    .block-name.hovered {{ fill: #00d4ff; }}
    .block-type  {{ font-family: 'Share Tech Mono', monospace; font-size: 8.5px;
                    fill: #4a7a99; }}
    .edge-line   {{ stroke: rgba(0,212,255,0.25); stroke-width: 1.5;
                    fill: none; transition: all 0.25s; }}
    .edge-line.hovered  {{ stroke: #00d4ff; stroke-width: 2.5;
                           filter: drop-shadow(0 0 4px #00d4ff66); }}
    .edge-label  {{ font-family: 'Share Tech Mono', monospace; font-size: 8px;
                    fill: #3a6a8a; }}
    .edge-label.hovered {{ fill: #00d4ff88; }}
    .arrowhead   {{ fill: rgba(0,212,255,0.4); }}
    .arrowhead.hovered {{ fill: #00d4ff; }}

    /* ── RIGHT: DETAILS PANEL ── */
    .detail-empty {{
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100%;
      color: var(--text-dim);
      font-family: var(--font-mono);
      font-size: 12px;
      text-align: center;
      gap: 12px;
    }}
    .detail-empty .hint {{
      font-size: 10px;
      color: #2a4a5a;
    }}
    .detail-section {{
      margin-bottom: 16px;
    }}
    .detail-section-title {{
      font-family: var(--font-head);
      font-size: 9px;
      letter-spacing: 2px;
      color: var(--cyan);
      text-transform: uppercase;
      margin-bottom: 8px;
      padding-bottom: 4px;
      border-bottom: 1px solid var(--border);
    }}
    .detail-name {{
      font-family: var(--font-head);
      font-size: 13px;
      color: var(--cyan);
      margin-bottom: 6px;
    }}
    .detail-row {{
      display: flex;
      gap: 8px;
      margin-bottom: 5px;
      font-size: 13px;
    }}
    .detail-row .dk {{ color: var(--amber); font-family: var(--font-mono); font-size: 11px;
                       min-width: 80px; flex-shrink: 0; }}
    .detail-row .dv {{ color: var(--text); font-size: 12px; word-break: break-word; }}
    .detail-desc {{
      background: rgba(0,212,255,0.04);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 10px 12px;
      font-size: 13px;
      line-height: 1.6;
      color: var(--text-dim);
      margin-bottom: 12px;
    }}
    .acts-list, .ints-list {{
      list-style: none;
    }}
    .acts-list li, .ints-list li {{
      padding: 5px 8px;
      border: 1px solid var(--border);
      border-radius: 4px;
      margin-bottom: 5px;
      font-size: 11px;
      font-family: var(--font-mono);
      color: var(--text-dim);
      cursor: pointer;
      transition: all 0.2s;
    }}
    .acts-list li:hover {{ border-color: var(--cyan-dim); color: var(--cyan);
                           background: rgba(0,212,255,0.04); }}
    .acts-list li .act-name {{ color: var(--amber); font-size: 10px; }}
    .legend {{
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 10px;
    }}
    .legend-item {{
      display: flex;
      align-items: center;
      gap: 5px;
      font-family: var(--font-mono);
      font-size: 10px;
      color: var(--text-dim);
    }}
    .legend-dot {{
      width: 10px;
      height: 10px;
      border-radius: 2px;
      border: 1px solid;
    }}

    /* ── SCROLLBAR ── */
    ::-webkit-scrollbar {{ width: 4px; }}
    ::-webkit-scrollbar-track {{ background: transparent; }}
    ::-webkit-scrollbar-thumb {{ background: var(--cyan-dim); border-radius: 2px; }}
  </style>
</head>
<body>

  <!-- TOP BAR -->
  <div class="top-bar">
    <div class="logo">MOSS<span> ▸ </span>{sys_name}</div>
    <div class="subtitle">
      <span class="dot"></span>
      {len(resources)} RESOURCES &nbsp;·&nbsp; {len(actions)} ACTIONS &nbsp;·&nbsp; {len(interfaces)} INTERFACES
    </div>
    <div class="badge">architecture_draft · 2026-04-22</div>
  </div>

  <!-- THREE PANELS -->
  <div class="panels">

    <!-- LEFT: MOSS CODE -->
    <div class="panel">
      <div class="panel-header"><span class="tag">MOSS</span> ARCHITECTURE SOURCE</div>
      <div class="panel-body">
        <div class="moss-code" id="mossCode"></div>
      </div>
    </div>

    <!-- CENTER: BLOCK DIAGRAM -->
    <div class="panel">
      <div class="panel-header"><span class="tag amber">R</span> COMPONENT DIAGRAM</div>
      <div class="panel-body" style="padding:8px; display:flex; flex-direction:column;">
        <div class="legend">
          <div class="legend-item">
            <div class="legend-dot" style="border-color:#00d4ff; background:rgba(0,212,255,0.1);"></div>
            IDE Core
          </div>
          <div class="legend-item">
            <div class="legend-dot" style="border-color:#ffaa00; background:rgba(255,170,0,0.1);"></div>
            Ollama
          </div>
          <div class="legend-item">
            <div class="legend-dot" style="border-color:#44ff88; background:rgba(68,255,136,0.1);"></div>
            Worker 1
          </div>
          <div class="legend-item">
            <div class="legend-dot" style="border-color:#bb88ff; background:rgba(187,136,255,0.1);"></div>
            Support
          </div>
        </div>
        <svg id="diagramSvg" viewBox="0 0 580 560" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
              <path d="M0,0 L0,6 L8,3 z" class="arrowhead" id="arrowMarker"/>
            </marker>
            <marker id="arrow-hover" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
              <path d="M0,0 L0,6 L8,3 z" fill="#00d4ff" id="arrowMarkerHover"/>
            </marker>
          </defs>

          <!-- Edges (drawn first, behind blocks) -->
          <!-- IDE_Frontend → IDE_Backend -->
          <line class="edge-line" id="e0" x1="290" y1="90" x2="290" y2="148" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el0" x="295" y="122" text-anchor="start">HTTP :5555</text>

          <!-- IDE_Backend → Ollama -->
          <line class="edge-line" id="e1" x1="362" y1="190" x2="430" y2="190" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el1" x="370" y="184" text-anchor="start">POST /api/generate</text>

          <!-- IDE_Backend → Script_Exec -->
          <line class="edge-line" id="e2" x1="290" y1="228" x2="290" y2="288" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el2" x="295" y="260" text-anchor="start">execute()</text>

          <!-- IDE_Backend → SSH_Bridge -->
          <line class="edge-line" id="e3" x1="218" y1="190" x2="150" y2="190" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el3" x="160" y="184" text-anchor="start">remote exec</text>

          <!-- SSH_Bridge → Worker1 -->
          <line class="edge-line" id="e4" x1="100" y1="228" x2="100" y2="358" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el4" x="105" y="295" text-anchor="start">SSH :22</text>

          <!-- Script_Exec → SSH_Bridge -->
          <line class="edge-line" id="e5" x1="218" y1="320" x2="150" y2="230" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el5" x="160" y="275" text-anchor="end">execute_remote()</text>

          <!-- IDE_Frontend → Remote_IDE_View (dashed flow to right) -->
          <line class="edge-line" id="e6" x1="362" y1="52" x2="460" y2="290" stroke-dasharray="5,3" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el6" x="415" y="165" text-anchor="start">right pane</text>

          <!-- Remote_IDE_View → SSH_Bridge -->
          <line class="edge-line" id="e7" x1="460" y1="330" x2="150" y2="200" stroke-dasharray="3,4" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el7" x="290" y="285" text-anchor="middle">data source</text>

          <!-- Ollama_Version_Coordinator → Ollama_Local_Server -->
          <line class="edge-line" id="e8" x1="480" y1="112" x2="480" y2="148" marker-end="url(#arrow)"/>
          <text class="edge-label" id="el8" x="485" y="132" text-anchor="start">version spec</text>

          <!-- IDE_Backend → Git_Integration -->
          <line class="edge-line" id="e9" x1="290" y1="228" x2="460" y2="430" stroke-dasharray="4,3" marker-end="url(#arrow)"/>

          <!-- IDE_Backend → File_System_Local -->
          <line class="edge-line" id="e10" x1="362" y1="210" x2="460" y2="470" stroke-dasharray="4,3" marker-end="url(#arrow)"/>

          <!-- ── BLOCKS ── -->

          <!-- IDE_Frontend_Windows  (top center) -->
          <g class="block-group" data-id="IDE_Frontend_Windows" transform="translate(190,20)">
            <rect class="block-rect" width="200" height="62" data-id="IDE_Frontend_Windows"/>
            <text class="block-label" x="8" y="14">R · IDE_CORE</text>
            <text class="block-name"  x="100" y="35" text-anchor="middle" data-id="IDE_Frontend_Windows">IDE Frontend</text>
            <text class="block-type"  x="100" y="50" text-anchor="middle">HTML/JS · Electron</text>
          </g>

          <!-- IDE_Backend_Windows  (center) -->
          <g class="block-group" data-id="IDE_Backend_Windows" transform="translate(190,150)">
            <rect class="block-rect" width="200" height="62" data-id="IDE_Backend_Windows"/>
            <text class="block-label" x="8" y="14">R · IDE_CORE</text>
            <text class="block-name"  x="100" y="35" text-anchor="middle" data-id="IDE_Backend_Windows">IDE Backend</text>
            <text class="block-type"  x="100" y="50" text-anchor="middle">Python FastAPI · :5555</text>
          </g>

          <!-- Ollama_Local_Server  (right) -->
          <g class="block-group" data-id="Ollama_Local_Server" transform="translate(432,150)">
            <rect class="block-rect ollama" width="140" height="62" data-id="Ollama_Local_Server"/>
            <text class="block-label" x="8" y="14" style="fill:#ffaa0099">R · OLLAMA</text>
            <text class="block-name"  x="70" y="35" text-anchor="middle" data-id="Ollama_Local_Server">Ollama</text>
            <text class="block-type"  x="70" y="50" text-anchor="middle">localhost:11434</text>
          </g>

          <!-- Ollama_Version_Coordinator (top-right) -->
          <g class="block-group" data-id="Ollama_Version_Coordinator" transform="translate(432,72)">
            <rect class="block-rect support" width="140" height="56" data-id="Ollama_Version_Coordinator"/>
            <text class="block-label" x="8" y="14" style="fill:#bb88ff99">R · CONFIG</text>
            <text class="block-name"  x="70" y="33" text-anchor="middle" style="font-size:10.5px;" data-id="Ollama_Version_Coordinator">Version Coordinator</text>
            <text class="block-type"  x="70" y="47" text-anchor="middle">ollama_version.txt</text>
          </g>

          <!-- Script_Execution_Engine  (center-bottom) -->
          <g class="block-group" data-id="Script_Execution_Engine" transform="translate(190,290)">
            <rect class="block-rect" width="200" height="62" data-id="Script_Execution_Engine"/>
            <text class="block-label" x="8" y="14">R · RUNTIME</text>
            <text class="block-name"  x="100" y="35" text-anchor="middle" data-id="Script_Execution_Engine">Script Engine</text>
            <text class="block-type"  x="100" y="50" text-anchor="middle">Python · Bash · PowerShell</text>
          </g>

          <!-- SSH_Worker1_Bridge  (left) -->
          <g class="block-group" data-id="SSH_Worker1_Bridge" transform="translate(10,150)">
            <rect class="block-rect" width="140" height="62" data-id="SSH_Worker1_Bridge"/>
            <text class="block-label" x="8" y="14">R · TUNNEL</text>
            <text class="block-name"  x="70" y="35" text-anchor="middle" data-id="SSH_Worker1_Bridge">SSH Bridge</text>
            <text class="block-type"  x="70" y="50" text-anchor="middle">ubuntu-atlas-01</text>
          </g>

          <!-- Worker_1_Ubuntu_System  (bottom-left) -->
          <g class="block-group" data-id="Worker_1_Ubuntu_System" transform="translate(10,360)">
            <rect class="block-rect worker" width="140" height="62" data-id="Worker_1_Ubuntu_System"/>
            <text class="block-label" x="8" y="14" style="fill:#44ff8899">R · EXTERNAL</text>
            <text class="block-name"  x="70" y="35" text-anchor="middle" data-id="Worker_1_Ubuntu_System">Worker 1 Ubuntu</text>
            <text class="block-type"  x="70" y="50" text-anchor="middle">ubuntu-worker-01</text>
          </g>

          <!-- Remote_IDE_View  (far right, middle) -->
          <g class="block-group" data-id="Remote_IDE_View" transform="translate(432,290)">
            <rect class="block-rect support" width="140" height="62" data-id="Remote_IDE_View"/>
            <text class="block-label" x="8" y="14" style="fill:#bb88ff99">R · DISPLAY</text>
            <text class="block-name"  x="70" y="35" text-anchor="middle" data-id="Remote_IDE_View">Remote IDE View</text>
            <text class="block-type"  x="70" y="50" text-anchor="middle">Right Pane</text>
          </g>

          <!-- Git_Integration  (bottom right) -->
          <g class="block-group" data-id="Git_Integration" transform="translate(432,420)">
            <rect class="block-rect support" width="140" height="50" data-id="Git_Integration"/>
            <text class="block-label" x="8" y="14" style="fill:#bb88ff99">R · VCS</text>
            <text class="block-name"  x="70" y="33" text-anchor="middle" data-id="Git_Integration">Git Integration</text>
            <text class="block-type"  x="70" y="45" text-anchor="middle">local .git</text>
          </g>

          <!-- File_System_Local  (bottom right) -->
          <g class="block-group" data-id="File_System_Local" transform="translate(432,480)">
            <rect class="block-rect support" width="140" height="50" data-id="File_System_Local"/>
            <text class="block-label" x="8" y="14" style="fill:#bb88ff99">R · STORAGE</text>
            <text class="block-name"  x="70" y="33" text-anchor="middle" data-id="File_System_Local">File System</text>
            <text class="block-type"  x="70" y="45" text-anchor="middle">c:\\AI Assistant\\...</text>
          </g>

        </svg>
      </div>
    </div>

    <!-- RIGHT: DETAILS -->
    <div class="panel">
      <div class="panel-header"><span class="tag green">INT</span> COMPONENT DETAILS</div>
      <div class="panel-body" id="detailPanel">
        <div class="detail-empty" id="detailEmpty">
          <div>← Hover a block to inspect</div>
          <div class="hint">
            R = Resource &nbsp;·&nbsp; ACT = Action &nbsp;·&nbsp; INT = Interface<br>
            {len(resources)} resources &nbsp;·&nbsp; {len(actions)} actions &nbsp;·&nbsp; {len(interfaces)} interfaces
          </div>
        </div>
        <div id="detailContent" style="display:none;"></div>
      </div>
    </div>

  </div>

<script>
// ════════════════════════════════════════════════════════════════
// DATA (compiled from MOSSCompiler + custom parser)
// ════════════════════════════════════════════════════════════════
const CODE_LINES    = {js_code_lines};
const COMP_DETAILS  = {js_comp_details};
const ACT_SUMMARY   = {js_act_summary};
const INT_SUMMARY   = {js_int_summary};
const EDGES         = {js_edges};
const ALL_RESOURCES = {js_resources};

// ════════════════════════════════════════════════════════════════
// BUILD LEFT PANEL: MOSS CODE
// ════════════════════════════════════════════════════════════════
const mossCodeEl = document.getElementById('mossCode');

// section-name extraction to allow linking code lines to blocks
const SECTION_RE = /^\\[([A-Z]+):?([^\\]]*)\\]$/;

CODE_LINES.forEach((line, idx) => {{
  const span = document.createElement('span');
  span.className = 'moss-line';
  span.dataset.idx = idx;

  // Detect section references
  const sm = SECTION_RE.exec(line.text || '');
  if (sm) {{
    const rname = sm[2].trim();
    if (rname) span.dataset.resource = rname;
  }}

  switch (line.type) {{
    case 'comment':
      span.innerHTML = `<span class="t-comment">${{esc(line.text)}}</span>`;
      break;
    case 'section':
      span.innerHTML = `<span class="t-section">${{esc(line.text)}}</span>`;
      break;
    case 'kv':
      span.innerHTML = `<span class="t-key">${{esc(line.k)}}:</span> <span class="t-val">${{esc(line.v)}}</span>`;
      break;
    case 'listitem':
      span.innerHTML = `<span class="t-listitem">${{esc(line.text)}}</span>`;
      break;
    case 'separator':
      span.innerHTML = `<span class="t-separator">---</span>`;
      break;
    case 'blank':
      span.innerHTML = '&nbsp;';
      break;
    default:
      span.textContent = line.text || '';
  }}

  mossCodeEl.appendChild(span);
}});

function esc(s) {{
  if (!s) return '';
  return String(s)
    .replace(/&/g,'&amp;')
    .replace(/</g,'&lt;')
    .replace(/>/g,'&gt;');
}}

// ════════════════════════════════════════════════════════════════
// BLOCK DIAGRAM INTERACTIONS
// ════════════════════════════════════════════════════════════════
const detailEmpty   = document.getElementById('detailEmpty');
const detailContent = document.getElementById('detailContent');

// Edge connectivity map: blockId → [edgeIdx, ...]
const EDGE_MAP = {{}};
EDGES.forEach((e, i) => {{
  (EDGE_MAP[e.from] = EDGE_MAP[e.from] || []).push(i);
  (EDGE_MAP[e.to]   = EDGE_MAP[e.to]   || []).push(i);
}});

function setEdgeHovered(edgeIdx, on) {{
  const line = document.getElementById(`e${{edgeIdx}}`);
  const lbl  = document.getElementById(`el${{edgeIdx}}`);
  if (line) line.classList.toggle('hovered', on);
  if (lbl)  lbl.classList.toggle('hovered', on);
}}

function setBlockHovered(id, on) {{
  const rects = document.querySelectorAll(`.block-rect[data-id="${{id}}"]`);
  const names = document.querySelectorAll(`.block-name[data-id="${{id}}"]`);
  rects.forEach(r => r.classList.toggle('hovered', on));
  names.forEach(n => n.classList.toggle('hovered', on));
}}

// Highlight MOSS code lines for this resource
function highlightMossLines(id, on) {{
  const spans = document.querySelectorAll('.moss-line');
  let inSection = false;
  spans.forEach(s => {{
    const res = s.dataset.resource;
    if (res === id) inSection = true;
    else if (res && res !== id && inSection) inSection = false;
    if (inSection) {{
      s.classList.toggle('highlight', on);
      if (on) s.scrollIntoView({{ block: 'nearest', behavior: 'smooth' }});
    }}
  }});
}}

// Show details for component
function showDetails(id) {{
  const comp = COMP_DETAILS[id];
  if (!comp) {{ detailEmpty.style.display='flex'; detailContent.style.display='none'; return; }}

  detailEmpty.style.display = 'none';
  detailContent.style.display = 'block';

  // Find related actions
  const relatedActs = Object.values(ACT_SUMMARY).filter(a =>
    a.trigger && a.trigger.toLowerCase().includes(id.toLowerCase().replace(/_/g,' '))
  );

  // Find related interfaces
  const relatedInts = Object.values(INT_SUMMARY).filter(i =>
    i.name.toLowerCase().includes(id.toLowerCase().replace(/_windows|_bridge/g,''))
  );

  detailContent.innerHTML = `
    <div class="detail-section">
      <div class="detail-section-title">Resource</div>
      <div class="detail-name">${{esc(comp.name)}}</div>
      ${{comp.type ? `<div class="detail-row"><span class="dk">Type</span><span class="dv">${{esc(comp.type)}}</span></div>` : ''}}
      ${{comp.language ? `<div class="detail-row"><span class="dk">Language</span><span class="dv">${{esc(comp.language)}}</span></div>` : ''}}
      ${{comp.port ? `<div class="detail-row"><span class="dk">Port</span><span class="dv">${{esc(comp.port)}}</span></div>` : ''}}
      ${{comp.location ? `<div class="detail-row"><span class="dk">Location</span><span class="dv">${{esc(comp.location)}}</span></div>` : ''}}
    </div>
    ${{comp.description ? `<div class="detail-desc">${{esc(comp.description)}}</div>` : ''}}
    ${{relatedActs.length ? `
      <div class="detail-section">
        <div class="detail-section-title">Related ACT Flows</div>
        <ul class="acts-list">
          ${{relatedActs.map(a => `<li><div class="act-name">${{esc(a.name)}}</div><div>${{esc(a.trigger).substring(0,80)}}</div></li>`).join('')}}
        </ul>
      </div>` : ''}}
    ${{relatedInts.length ? `
      <div class="detail-section">
        <div class="detail-section-title">Interfaces</div>
        <ul class="ints-list">
          ${{relatedInts.map(i => `<li>${{esc(i.name)}} — ${{esc(i.protocol)}}</li>`).join('')}}
        </ul>
      </div>` : ''}}
    <div class="detail-section">
      <div class="detail-section-title">Connections</div>
      <ul class="acts-list">
        ${{(EDGE_MAP[id] || []).map(ei => {{
          const e = EDGES[ei];
          return `<li style="color:var(--cyan-dim)">${{esc(e.from)}} → ${{esc(e.to)}}${{e.label ? ` <span style="color:#4a7a99"> (${{esc(e.label)}})</span>` : ''}}</li>`;
        }}).join('')}}
      </ul>
    </div>
  `;
}}

// Attach hover + click to all block groups
document.querySelectorAll('.block-group').forEach(g => {{
  const id = g.dataset.id;
  if (!id) return;

  g.addEventListener('mouseenter', () => {{
    setBlockHovered(id, true);
    (EDGE_MAP[id] || []).forEach(ei => setEdgeHovered(ei, true));
    highlightMossLines(id, true);
    showDetails(id);
  }});

  g.addEventListener('mouseleave', () => {{
    setBlockHovered(id, false);
    (EDGE_MAP[id] || []).forEach(ei => setEdgeHovered(ei, false));
    highlightMossLines(id, false);
  }});

  g.addEventListener('click', () => {{
    showDetails(id);
    highlightMossLines(id, true);
    setTimeout(() => highlightMossLines(id, false), 3000);
  }});
}});

</script>
</body>
</html>
"""

# ── Write output ──────────────────────────────────────────────────────────────
OUTPUT_HTML.parent.mkdir(parents=True, exist_ok=True)
OUTPUT_HTML.write_text(html, encoding="utf-8")
print(f"[OK] Visualization written to: {OUTPUT_HTML}")
print(f"     Size: {OUTPUT_HTML.stat().st_size:,} bytes")
