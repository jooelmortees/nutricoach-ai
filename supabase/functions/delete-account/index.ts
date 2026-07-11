// ============================================================
// delete-account - Edge Function de Supabase
// Borra TODOS los datos del usuario y su cuenta de auth.
// Requiere autenticacion (JWT del propio usuario). Usa service_role
// para bypasear RLS y llamar a admin.deleteUser().
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "app.nutricoach://",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonError(401, "Missing Authorization header");
    }

    // 1. Identificar al usuario con el token JWT
    const supabaseUser = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !user) {
      return jsonError(401, "Invalid token");
    }

    // 2. Cliente con service_role (bypasea RLS) para borrar datos
    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 3. Borrar datos del usuario en orden (respetando FKs)
    // Orden: tablas hijas primero, padres despues.
    const tablesToDelete = [
      "messages",
      "conversations",
      "meal_items",
      "meals",
      "recipes",
      "meal_plans",
      "health_metrics",
      "user_facts",
      "memory_embeddings",
      "user_preferences",
      "scheduled_nudges",
      "audit_log",
    ];

    const errors: string[] = [];

    for (const table of tablesToDelete) {
      const { error } = await supabaseAdmin
        .from(table)
        .delete()
        .eq("user_id", user.id);
      if (error) {
        // Algunas tablas pueden no tener user_id (ej: meal_items tiene meal_id)
        // o no tener filas. Lo registramos pero continuamos.
        errors.push(`${table}: ${error.message}`);
      }
    }

    // 4. Borrar el perfil (tiene FK a auth.users.id, se borra en cascade
    //    al borrar el user de auth, pero lo hacemos explicito por si acaso)
    await supabaseAdmin
      .from("profiles")
      .delete()
      .eq("id", user.id);

    // 5. Borrar objetos de Storage del usuario (meal-photos y meal-videos)
    const storageBuckets = ["meal-photos", "meal-videos"];
    for (const bucket of storageBuckets) {
      try {
        const { data: folders } = await supabaseAdmin
          .storage
          .from(bucket)
          .list(user.id, { limit: 100 });
        if (folders && folders.length > 0) {
          const filesToDelete = folders.map(f => `${user.id}/${f.name}`);
          await supabaseAdmin
            .storage
            .from(bucket)
            .remove(filesToDelete);
        }
      } catch (storageErr) {
        errors.push(`${bucket}: ${String(storageErr)}`);
      }
    }

    // 6. Borrar el usuario de auth.users (esto borra el perfil en cascade
    //    por la FK profiles.id -> auth.users.id con ON DELETE CASCADE)
    const { error: deleteErr } = await supabaseAdmin.auth.admin.deleteUser(
      user.id,
      { shouldRevokeSessions: true }
    );
    if (deleteErr) {
      return jsonError(500, `Error borrando usuario de auth: ${deleteErr.message}`);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        deleted_tables: tablesToDelete.length,
        warnings: errors.length > 0 ? errors : undefined,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return jsonError(500, String(err));
  }
});

function jsonError(status: number, message: string) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}