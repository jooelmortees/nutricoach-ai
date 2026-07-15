# Tools del Agente

> El agente tiene acceso a 34+ herramientas distribuidas en 7 namespaces MCP + 1 oficial (web_search).

## Estado de implementación

| Tool | Namespace | Fase |
|---|---|---|
| `get_user_profile` | direct | 1 ✅ |
| `update_profile` | user-data | 2 |
| `remember_fact` | memory | 1 ✅ |
| `recall_facts` | memory | 1 ✅ (texto) → 4 (semántico) |
| `forget_fact` | memory | 1 ✅ |
| `list_recent_facts` | memory | 1 ✅ |
| `add_memory_embedding` | memory | 4 |
| `search_memories` | memory | 4 |
| `search_food` | nutrition | 3 |
| `get_food_details` | nutrition | 3 |
| `analyze_meal_photo` | nutrition | 2 (usa Gemini vision directo en chat-proxy) |
| `analyze_meal_video` | nutrition | 5 |
| `analyze_meal_text` | nutrition | 1 |
| `log_meal` | nutrition | 2 |
| `get_meal_history` | nutrition | 2 |
| `scan_barcode` | nutrition | 2 |
| `calculate_tdee` | nutrition | 1 ✅ |
| `calculate_macros` | nutrition | 1 ✅ |
| `check_food_compatibility` | nutrition | 3 |
| `suggest_substitutions` | nutrition | 3 |
| `search_exercise` | fitness | 4 |
| `get_exercise_info` | fitness | 4 |
| `log_workout` | fitness | 4 |
| `get_workout_history` | fitness | 4 |
| `get_health_summary` | wearable | 2 |
| `get_sleep_last_night` | wearable | 2 |
| `get_heart_rate_summary` | wearable | 2 |
| `get_recent_workouts` | wearable | 2 |
| `analyze_health_pattern` | wearable | 4 |
| `generate_meal_plan` | plans | 3 |
| `get_active_meal_plan` | plans | 1 ✅ |
| `generate_daily_plan` | plans | 3 |
| `generate_shopping_list` | plans | 3 |
| `swap_meal` | plans | 3 |
| `schedule_nudge` | nudges | 5 |
| `web_search` | Gemini grounding (Google Search) | 1 ✅ |
| `list_recipes` | recipes | 5 |
| `get_recipe` | recipes | 5 |
| `create_recipe` | recipes | 5 |
| `start_fasting` | fasting | 5 |
| `end_fasting` | fasting | 5 |
| `get_fasting_status` | fasting | 5 |

## Diseño de los tools

Todos los tools siguen el formato Anthropic function calling:

```json
{
  "name": "namespace.method",
  "description": "Descripción clara y concisa de qué hace",
  "input_schema": {
    "type": "object",
    "properties": {
      "param1": { "type": "string", "description": "..." }
    },
    "required": ["param1"]
  }
}
```

## Reglas para añadir un tool nuevo

1. **Una sola responsabilidad**: el tool hace una cosa y la hace bien
2. **Descripción concisa pero completa**: el LLM la lee, si es ambigua hará tool calls incorrectos
3. **Validación en backend**: nunca confíes en la entrada; valida antes de tocar la BD
4. **Manejo de errores claro**: devuelve `{ok: false, error: "..."}` en lugar de tirar
5. **Idempotente cuando sea posible**: que se pueda llamar dos veces sin efectos raros
6. **Logs**: registra cada llamada para auditoría
7. **Tests**: añade test unitario del tool en el backend

## Cómo se invocan

El loop del agente (en `chat-proxy`) es:

```ts
let response = await anthropic.messages.create({
  model: "gemini-3.5-flash",
  messages, tools, reasoning_effort: "medium"
})

while (response.stop_reason === "tool_use") {
  const toolUse = response.content.find(c => c.type === "tool_use")
  const result = await fetch("mcp-router", { tool: toolUse.name, arguments: toolUse.input })
  // Añadir al historial y seguir
  messages.push({ role: "assistant", content: response.content })
  messages.push({ role: "user", content: [{ type: "tool_result", tool_use_id: toolUse.id, content: JSON.stringify(result) }] })
  response = await anthropic.messages.create({ model, messages, tools, thinking })
}
```

Importante: **preservar TODOS los content blocks** (thinking + text + tool_use) al añadir al historial. Si se pierde el thinking, Gemini pierde la cadena de razonamiento.
