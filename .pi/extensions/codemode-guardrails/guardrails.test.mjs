// Pi-only regression tests; no running Pi session or model credentials required.
import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import extension from "./index.ts";
import { guardSource, preflight } from "./guardrails.mjs";

const catalog = [
  { name: "read", exposure: "direct" }, { name: "write", exposure: "direct" },
  { name: "subagents_enable", exposure: "model-only" },
  { name: "lookup", exposure: "deferred" }, { name: "hidden", exposure: "hidden" },
];
const active = ["read", "write", "subagents_enable"];
const block = { type: "image", data: "BASE64_SENTINEL", mimeType: "image/png" };

async function run(source, overrides = {}) {
  const texts = [], images = [], logs = [];
  const sandbox = {
    tools: { read: async () => block, ...overrides },
    text: (value) => texts.push(value), image: (value) => images.push(value),
    console: Object.fromEntries(["log", "info", "warn", "error", "debug"].map((name) => [name, (...values) => logs.push(values)])),
  };
  const code = guardSource(source, catalog, active);
  await vm.runInNewContext(`(async () => { ${code}\n })()`, sandbox);
  assert.ok(!JSON.stringify({ texts, logs }).includes("BASE64_SENTINEL"));
  return { texts, images, logs };
}

test("historical batch fails preflight before any write starts", () => {
  assert.throws(() => guardSource('await Promise.allSettled([tools.write({}), tools.subagents_enable({})]);', catalog, active), /model-only.*no tools.*started/);
});
test("computed literal, optional access and destructuring are checked", () => {
  for (const source of ['tools["subagents_enable"]({})', 'tools?.subagents_enable({})', 'const {subagents_enable: enable} = tools; enable({})']) {
    assert.throws(() => preflight(source, catalog, active), /model-only/);
  }
});
test("inactive, hidden and missing tools fail; deferred tools remain callable", () => {
  for (const source of ['tools.missing({})', 'tools.hidden({})', 'tools.read({})']) {
    assert.throws(() => preflight(source, catalog, []), /not currently callable/);
  }
  preflight('tools.lookup({})', catalog, []);
});
test("comments and strings are not tool references", () => {
  preflight('// tools.missing({})\ntext("tools.subagents_enable({})");', catalog, active);
});
test("image passed to text is emitted as an image without base64 text", async () => {
  const result = await run('text(await tools.read({path:"image.png"}));');
  assert.equal(result.images.length, 1);
  assert.equal(result.images[0].data, block.data);
});
test("nested image, console and top-level return use the same output boundary", async () => {
  const result = await run('const b=await tools.read({}); text({results:[b]}); console.warn(b); return b;');
  assert.equal(result.images.length, 3);
});
test("plain text, structured data, errors and explicit image keep their behavior", async () => {
  const result = await run('text("hello"); console.log("ok", 3); image(await tools.read({})); return {ok:true};');
  assert.equal(result.texts[0], "hello");
  assert.equal(result.texts[1].ok, true);
  assert.equal(result.images.length, 1);
  await assert.rejects(run('throw new Error("original failure")'), /original failure/);
});
test("Pi hook uses live exposure and adds Pi-labelled guidance", () => {
  const handlers = {};
  extension({ on: (name, callback) => { handlers[name] = callback; }, getAllTools: () => catalog, getActiveTools: () => active });
  assert.equal(handlers.tool_call({toolName:"read", input:{path:"file"}}), undefined);
  const blocked = handlers.tool_call({toolName:"codemode", input:{code:"tools.subagents_enable({})"}});
  assert.equal(blocked.block, true);
  const event = {toolName:"codemode", input:{code:'return "ok"'}};
  assert.equal(handlers.tool_call(event), undefined);
  assert.ok(event.input.code.includes("installOutputGuard"));
  const prompt = {systemPromptOptions:{selectedTools:["codemode"], toolGuidelines:{}}};
  handlers.before_agent_start(prompt);
  assert.match(prompt.systemPromptOptions.toolGuidelines.codemode[0], /Pi only/);
});

test("Pi injects its contract before enabling subagents, without duplicating or retaining stale sections", () => {
  const handlers = {};
  extension({on:(name, callback) => { handlers[name]=callback; }});
  const prompt = {systemPromptOptions:{selectedTools:["subagents_enable"], toolGuidelines:{}, sections:{unrelated:"keep"}}};
  handlers.before_agent_start(prompt);
  const expected = readFileSync(new URL("./orchestration.md", import.meta.url), "utf8");
  assert.equal(prompt.systemPromptOptions.sections.winductor_pi_orchestration, expected);
  assert.ok(expected.includes("async: true"));
  for (const tool of ["subagent", "subagent_supervisor", "subagents_enable"]) {
    prompt.systemPromptOptions.selectedTools = [tool];
    handlers.before_agent_start(prompt);
    assert.equal(prompt.systemPromptOptions.sections.winductor_pi_orchestration, expected);
  }
  prompt.systemPromptOptions.selectedTools = ["read"];
  handlers.before_agent_start(prompt);
  assert.deepEqual(prompt.systemPromptOptions.sections, {unrelated:"keep"});
});

test("codemode alone does not load the subagent contract", () => {
  const handlers = {};
  extension({on:(name, callback) => { handlers[name]=callback; }});
  const prompt = {systemPromptOptions:{selectedTools:["codemode"], toolGuidelines:{}, sections:{}}};
  handlers.before_agent_start(prompt);
  assert.equal(prompt.systemPromptOptions.sections.winductor_pi_orchestration, undefined);
  assert.match(prompt.systemPromptOptions.toolGuidelines.codemode[0], /\.pi\/extensions\/codemode-guardrails\/README\.md/);
});

test("shared harness entry points contain no Pi-specific instructions or pointers", () => {
  for (const path of ["../../../AGENTS.md", "../../../docs/agents/orchestration.md", "../../../.agents/skills/code-review/SKILL.md"]) {
    const content = readFileSync(new URL(path, import.meta.url), "utf8");
    assert.doesNotMatch(content, /pi-subagents|Pi agent only|\.pi\/|async: true/, path);
  }
});

test("Pi blocks synchronous launches but permits async launch and management", () => {
  const handlers = {};
  extension({on:(name, callback) => { handlers[name]=callback; }});
  assert.equal(handlers.tool_call({toolName:"subagent", input:{agent:"reviewer", async:false}}).block, true);
  assert.equal(handlers.tool_call({toolName:"subagent", input:{workflow:"parallel", async:false}}).block, true);
  assert.equal(handlers.tool_call({toolName:"subagent", input:{agent:"reviewer", async:true}}), undefined);
  assert.equal(handlers.tool_call({toolName:"subagent", input:{action:"status", async:false}}), undefined);
});

test("native Pi QuickJS image/text/console/return smoke", {skip: !process.env.PI_CODEMODE_EXECUTOR}, async () => {
  const {executeCodemode} = await import(pathToFileURL(process.env.PI_CODEMODE_EXECUTOR).href);
  const data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDaoAAAAASUVORK5CYII=";
  const source = `const b={type:"image",mimeType:"image/png",data:${JSON.stringify(data)}}; text(b); console.log({b}); return b;`;
  const result = await executeCodemode("guardrails-smoke", {code:guardSource(source, [], [])});
  assert.notEqual(result.isError, true, JSON.stringify(result.content));
  assert.equal(result.content.filter((item) => item.type === "image").length, 3, JSON.stringify(result.content.filter((item) => item.type === "text")));
  assert.ok(!result.content.filter((item) => item.type === "text").map((item) => item.text).join("\n").includes(data));
});

test("options stay first and top-level return does not double emit", async () => {
  const source = '// @options: {"max_output_tokens":2000}\nreturn "done";';
  assert.ok(guardSource(source, catalog, active).startsWith('// @options:'));
  assert.deepEqual((await run(source)).texts, ["done"]);
});
