// ============================================================
// providers - Configuracion de proveedores LLM
// Texto, vision y planes: OpenCode Go (DeepSeek V4.1 Flash).
// Notas de voz: Gemini 3.5 Flash (unico que procesa input_audio).
// Si OPENCODE_GO_API_KEY no esta configurada, todo degrada a Gemini.
// ============================================================

export interface LlmProviderConfig {
  label: string;
  apiKey: string;
  baseUrl: string;
  primaryModel: string;
  fallbackModel: string;
}

const DEFAULT_GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai";
const DEFAULT_GO_BASE_URL = "https://opencode.ai/zen/go/v1";

export function openCodeGoConfig(): LlmProviderConfig | null {
  const apiKey = Deno.env.get("OPENCODE_GO_API_KEY");
  if (!apiKey) return null;
  return {
    label: "OpenCode Go",
    apiKey,
    baseUrl: Deno.env.get("OPENCODE_GO_BASE_URL") ?? DEFAULT_GO_BASE_URL,
    primaryModel: Deno.env.get("OPENCODE_GO_MODEL") ?? "deepseek-v4.1-flash",
    fallbackModel: Deno.env.get("OPENCODE_GO_FALLBACK_MODEL") ?? "glm-5.3-flash",
  };
}

export function geminiConfig(): LlmProviderConfig {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    throw new Error("GEMINI_API_KEY no esta configurada");
  }
  return {
    label: "Gemini",
    apiKey,
    baseUrl: Deno.env.get("GEMINI_BASE_URL") ?? DEFAULT_GEMINI_BASE_URL,
    primaryModel: Deno.env.get("GEMINI_MODEL") ?? "gemini-3.5-flash",
    fallbackModel: Deno.env.get("GEMINI_FALLBACK_MODEL") ?? "gemini-3.1-flash-lite",
  };
}

/** Proveedor para texto, vision y planes: OpenCode Go si esta configurado; si no, Gemini. */
export function textProvider(): LlmProviderConfig {
  const go = openCodeGoConfig();
  if (go) return go;
  console.warn("OPENCODE_GO_API_KEY no configurada: usando Gemini por defecto");
  return geminiConfig();
}