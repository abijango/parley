function se() { return Application("System Events"); }
function proc() { return se().processes.byName("Parley"); }

function val(fn) {
  try {
    const v = fn();
    return v == null ? "" : String(v);
  } catch (e) {
    return "";
  }
}

function activateParley() {
  delay(0.15);
  try { proc().frontmost = true; } catch (e) {}
}

function walk(el, depth, n, visit) {
  if (n.count > 400 || depth > 14) return;
  n.count++;
  const role = val(() => el.role());
  visit(el, depth);
  if (role === "AXList" || role === "AXTable" || role === "AXOutline"
      || role === "AXScrollBar" || role === "AXScrollArea" || role === "AXWebArea") {
    return;
  }
  let kids = [];
  try { kids = el.uiElements(); } catch (e) { kids = []; }
  const limit = kids.length > 40 ? 40 : kids.length;
  for (let i = 0; i < limit; i++) walk(kids[i], depth + 1, n, visit);
}

function dump() {
  const wins = proc().windows();
  const lines = ["windows: " + wins.length];
  for (let i = 0; i < wins.length; i++) {
    const win = wins[i];
    lines.push("— window[" + i + "] title=" + JSON.stringify(val(() => win.name())));
    walk(win, 0, { count: 0 }, function (el, depth) {
      const role = val(() => el.role());
      const name = val(() => el.name());
      const title = val(() => el.title());
      const desc = val(() => el.description());
      const help = val(() => el.help());
      const value = val(() => el.value());
      const bits = [role];
      if (name) bits.push("name=" + JSON.stringify(name));
      if (title) bits.push("title=" + JSON.stringify(title));
      if (desc) bits.push("desc=" + JSON.stringify(desc));
      if (help) bits.push("help=" + JSON.stringify(help));
      if (value) bits.push("value=" + JSON.stringify(value));
      lines.push("  ".repeat(depth) + bits.join(" "));
    });
  }
  return lines.join("\n");
}

function labels(el) {
  return [
    val(() => el.name()),
    val(() => el.title()),
    val(() => el.description()),
    val(() => el.help()),
    val(() => el.value()),
  ].filter(function (s) { return s && s.length; });
}

function matches(el, name, roleWanted) {
  if (roleWanted) {
    const role = val(() => el.role());
    if (role.toLowerCase().indexOf(roleWanted.toLowerCase()) < 0) return false;
  }
  const n = name.toLowerCase();
  const ls = labels(el);
  for (let i = 0; i < ls.length; i++) {
    const s = ls[i].toLowerCase();
    if (s === n || s.indexOf(n) >= 0) return true;
  }
  return false;
}

function clickNamed(name, roleWanted) {
  activateParley();
  const wins = proc().windows();
  let hit = null;
  let hitMeta = "";
  for (let i = 0; i < wins.length; i++) {
    walk(wins[i], 0, { count: 0 }, function (el) {
      if (hit) return;
      if (matches(el, name, roleWanted)) {
        hit = el;
        hitMeta = val(() => el.role()) + " " + labels(el).join("|");
      }
    });
    if (hit) break;
  }
  if (!hit) {
    throw new Error("no AX element matching name=" + JSON.stringify(name) + " role=" + (roleWanted || "*"));
  }
  hit.click();
  return "clicked " + name + " via " + hitMeta;
}

function run(argv) {
  const cmd = argv[0];
  if (cmd === "dump") {
    return dump();
  }
  if (cmd === "activate") {
    activateParley();
    return "activated";
  }
  if (cmd === "click") {
    return clickNamed(argv[1], argv[2] || "");
  }
  throw new Error("unknown jxa command " + cmd);
}
