// Native pz tool presentation only: no tool interception or execution changes.
// Add this file to your plugin paths. All callbacks are synchronous.
export default function prettyTools(pz) {
  const color = { label: 0x89b4fa, muted: 0x9399b2, good: 0xa6e3a1, bad: 0xf38ba8 };
  // Remove terminal controls, including C1, before constructing native spans.
  function safe(value) {
    return String(value == null ? "" : value)
      .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
      .replace(/[\x00-\x1f\x7f-\x9f]/g, " ")
      .slice(0, 240)
      .replace(/[\ud800-\udfff]/g, "?");
  }
  function describe(name, input) {
    const args = input && typeof input === "object" ? input : {};
    if (name === "bash") return args.cmd || args.command || "shell command";
    if (name === "grep") return args.pattern || "search";
    return args.path || args.pattern || args.name || ".";
  }
  function render(event) {
    const failed = event.isError === true;
    const label = event.phase === "call" ? "running" : failed ? "error" : "done";
    const summary = [
      { text: safe(event.toolName) + " ", fg: color.label, bold: true },
      { text: safe(describe(event.toolName, event.input)) },
      { text: "  " + label, fg: failed ? color.bad : color.muted }
    ];
    if (event.inputTruncated) summary.push({ text: " [input truncated]", fg: color.muted });
    const collapsed = [summary];
    const expanded = [summary];
    // At most 48 preview rows, each one <=240 UTF-16 code units. Combined
    // collapsed/expanded text stays below 64 KiB even at four UTF-8 bytes/unit.
    const output = typeof event.output === "string" ? event.output : "";
    const lines = output.split(/\r\n|\n|\r/, 49);
    if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
    const count = Math.min(lines.length, 48);
    if (output) {
      let group = "";
      for (let i = 0; i < count; i++) {
        const line = safe(lines[i]);
        if (event.toolName === "ls" && !failed) {
          const directory = line.endsWith("/");
          const icon = directory ? "\uf07b" : /\.(js|ts|jsx|tsx)$/.test(line) ? "\ue74e" : /\.(png|jpg|webp|gif)$/.test(line) ? "\uf1c5" : "\uf15b";
          expanded.push([
            { text: i + 1 === count ? "└── " : "├── ", fg: color.muted },
            { text: icon + " " + line, fg: directory ? color.label : color.good }
          ]);
        } else if ((event.toolName === "find" || event.toolName === "grep") && !failed) {
          const match = event.toolName === "grep" ? /^(.+?):(\d+):(.*)$/.exec(line) : null;
          const path = match ? match[1] : line;
          const slash = path.lastIndexOf("/");
          const heading = match ? path : slash >= 0 ? path.slice(0, slash) : ".";
          if (heading !== group) {
            expanded.push([{ text: "\uf07b " + heading, fg: color.label, bold: true }]);
            group = heading;
          }
          expanded.push(match ? [
            { text: "  " + match[2] + ": ", fg: color.muted },
            { text: match[3], fg: color.good }
          ] : [{ text: "  └── " + path.slice(slash + 1), fg: color.good }]);
        } else {
          expanded.push([{ text: line, fg: failed ? color.bad : color.good }]);
        }
      }
    }
    if (event.outputTruncated || lines.length > 48) {
      expanded.push([{ text: "… preview truncated", fg: color.muted, italic: true }]);
    }
    return { collapsed, expanded };
  }
  // Explicit opt-in: unrelated tools retain their built-in presentation.
  for (const name of ["read", "bash", "ls", "find", "grep"]) {
    pz.registerToolRenderer({tool: name, render});
  }
}
