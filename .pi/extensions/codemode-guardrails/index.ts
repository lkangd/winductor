// Pi agent only. Auto-loaded for this trusted project; no product/runtime dependency.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { guardSource } from "./guardrails.mjs";

export default function (pi: ExtensionAPI) {
  const orchestration = readFileSync(new URL("./orchestration.md", import.meta.url), "utf8");
  pi.on("tool_call", (event) => {
    if (event.toolName === "subagent" && !event.input.action && event.input.async === false) {
      return { block: true, reason: "[Pi only] Blocking subagent launches can prevent supervisor replies. Launch with async: true and use native completion notifications." };
    }
    if (event.toolName !== "codemode") return;
    try {
      event.input.code = guardSource(event.input.code as string, pi.getAllTools(), pi.getActiveTools());
    } catch (error) {
      return { block: true, reason: error instanceof Error ? error.message : String(error) };
    }
  });
  pi.on("before_agent_start", (event) => {
    const options = event.systemPromptOptions;
    const sections = options.sections ??= {};
    if (["subagent", "subagents_enable", "subagent_supervisor"].some((name) => options.selectedTools?.includes(name))) {
      sections.winductor_pi_orchestration = orchestration;
    } else {
      delete sections.winductor_pi_orchestration;
    }
    if (!event.systemPromptOptions.selectedTools?.includes("codemode")) return;
    event.systemPromptOptions.toolGuidelines.codemode = [
      ...(event.systemPromptOptions.toolGuidelines.codemode ?? []),
      "[Pi only] codemode preflights literal tools.name references against active tool exposure. Call model-only tools directly. Typed image objects in text/console/return are routed to image(); prefer image(block) explicitly. Setup/reference: .pi/extensions/codemode-guardrails/README.md.",
    ];
  });
}
