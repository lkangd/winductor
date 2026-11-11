// Pi-only: runs at codemode's tool_call boundary, before any nested tool starts.
import { parse } from "acorn";

const identifier = (name) => name.replace(/[^a-zA-Z0-9_$]/g, "_");

function visit(node, fn) {
  if (!node || typeof node !== "object") return;
  if (typeof node.type === "string") fn(node);
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) value.forEach((child) => visit(child, fn));
    else if (value && typeof value === "object") visit(value, fn);
  }
}

export function preflight(source, catalog, activeNames) {
  const active = new Set(activeNames);
  const byIdentifier = new Map(catalog.map((tool) => [identifier(tool.name), tool]));
  // An async function body supports the same top-level await/return as codemode.
  const tree = parse(`async function script() {\n${source}\n}`, { ecmaVersion: "latest" });
  const references = new Set();
  visit(tree, (node) => {
    if (node.type === "MemberExpression" && node.object.type === "Identifier" && node.object.name === "tools") {
      const name = node.computed ? node.property.value : node.property.name;
      if (typeof name === "string") references.add(name);
    }
    if (node.type === "VariableDeclarator" && node.init?.type === "Identifier" && node.init.name === "tools" && node.id.type === "ObjectPattern") {
      for (const property of node.id.properties) {
        const name = property.computed ? property.key?.value : property.key?.name ?? property.key?.value;
        if (typeof name === "string") references.add(name);
      }
    }
  });
  for (const name of references) {
    const tool = byIdentifier.get(name);
    if (tool?.exposure === "model-only") {
      throw new Error(`[Pi only] ${tool.name} is model-only. Call it directly, outside codemode; no tools in this script have started.`);
    }
    const callable = tool && tool.name !== "codemode" && (
      ["codemode", "deferred"].includes(tool.exposure) ||
      ((tool.exposure ?? "direct") === "direct" && active.has(tool.name))
    );
    if (!callable) {
      throw new Error(`[Pi only] tools.${name} is not currently callable. Discover/activate it first, or call a model-only tool directly; no tools in this script have started.`);
    }
  }
}

// Serialized into QuickJS, so keep this function self-contained (no Node imports).
function installOutputGuard(rawText, rawConsole, emitImage) {
  const clean = (value) => {
    const images = [];
    const encoded = JSON.stringify(value, (_key, item) => {
      if (item && typeof item === "object" && item.type === "image" && typeof item.data === "string" && typeof item.mimeType === "string") {
        images.push(item);
        return { type: "image", mimeType: item.mimeType, note: "Emitted with image(), not base64 text." };
      }
      return item;
    });
    for (const block of images) emitImage(block);
    return images.length ? JSON.parse(encoded) : value;
  };
  return {
    text: (value) => rawText(clean(value)),
    console: Object.fromEntries(["log", "info", "warn", "error", "debug"].map((name) => [
      name, (...values) => rawConsole[name](...values.map(clean)),
    ])),
  };
}

export function guardSource(source, catalog, activeNames) {
  preflight(source, catalog, activeNames);
  // Keep the options line first; Pi rejects options anywhere else in the script.
  const match = source.match(/^([ \t]*\/\/ @options:[^\n]*\n?)/);
  const header = match?.[1] ?? "";
  const body = match ? source.slice(header.length) : source;
  return `${header}${header && !header.endsWith("\n") ? "\n" : ""}const __winductorGuard = (${installOutputGuard.toString()})(text, console, image);\nconst __winductorResult = await (async (text, console) => {\n${body}\n})(__winductorGuard.text, __winductorGuard.console);\nif (__winductorResult !== undefined) __winductorGuard.text(__winductorResult);`;
}
