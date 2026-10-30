// Edge Function `diag-questar-unidade` — diagnóstico SÓ DE LEITURA (30/10/2026, pedido do Jefferson):
// chama a ação "api_get_data" da Questar para uma placa e devolve a ESTRUTURA da resposta, para saber se
// ela traz nível de bateria (SOC), hodômetro e ignição — base do monitor de elétricos a cada 15 min.
//
// Não grava nada no banco. O token fica no segredo QUESTAR_API_TOKEN (nunca sai daqui).
// Privacidade (regra do projeto: Questar sem localização nem nome): de cada campo devolve só o caminho e o tipo;
// o VALOR só aparece em campos cujo nome indica bateria, carga, hodômetro/km, ignição, motor, velocidade ou horário,
// e nunca se o nome indicar localização, endereço, motorista ou nome de pessoa.
//
// Chamada (POST JSON): { placas: ["TUM7D88"] }   (até 3 placas; tenta também com hífen "TUM-7D88")
// Permissão: x-automation-key (Vault automation_secret_questar) ou JWT de admin ativo.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const QUESTAR_TOKEN = Deno.env.get("QUESTAR_API_TOKEN");
const QUESTAR_URL = "https://app.questar.io/v2/questar-units/api";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function autorizado(req: Request) {
  const chave = req.headers.get("x-automation-key") || "";
  if (chave) {
    const { data, error } = await db().rpc("verificar_automation_key", { chave });
    if (!error && data === true) return true;
  }
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return false;
  const { data: u, error } = await admin.auth.getUser(jwt);
  if (error || !u?.user) return false;
  const { data: p } = await db().from("usuarios_perfil").select("papel, ativo").eq("user_id", u.user.id).maybeSingle();
  return !!(p && p.ativo && p.papel === "admin");
}

const PROIBIDO = /(lat|lon|lng|gps|coord|geo|address|endere|street|rua|city|cidade|bairro|cep|zip|location|local|place|position|posic|driver|motorista|condutor|name|nome|phone|fone|email|cpf|rfid|ibutton|card|cartao)/i;
const PERMITIDO = /(bat|soc|charg|carga|energ|volt|odo|mileage|km|hodo|distan|ign|igni|engine|motor|speed|veloc|time|date|hora|data|status|state|estado|online|last|ultim|fuel|combust|range|autonom|plate|placa|license|unit|id$)/i;

// percorre o JSON e devolve [{ caminho, tipo, valor? }] (no máximo 400 campos)
function estrutura(obj: unknown) {
  const out: { caminho: string; tipo: string; valor?: unknown }[] = [];
  const andar = (v: unknown, caminho: string, chave: string) => {
    if (out.length >= 400) return;
    if (Array.isArray(v)) {
      out.push({ caminho, tipo: "lista(" + v.length + ")" });
      v.slice(0, 3).forEach((x, i) => andar(x, caminho + "[" + i + "]", chave));
      return;
    }
    if (v && typeof v === "object") {
      if (caminho) out.push({ caminho, tipo: "objeto" });
      // formato comum da Questar: { name: "...", value: "..." } → trata o "name" como a chave
      const o = v as Record<string, unknown>;
      if (typeof o.name === "string" && "value" in o && Object.keys(o).length <= 4) {
        const nomeParam = o.name;
        const item: { caminho: string; tipo: string; valor?: unknown } = { caminho: caminho + " {name=" + nomeParam + "}", tipo: typeof o.value };
        if (!PROIBIDO.test(nomeParam) && PERMITIDO.test(nomeParam)) item.valor = o.value;
        out.push(item);
        return;
      }
      for (const k of Object.keys(o)) andar(o[k], caminho ? caminho + "." + k : k, k);
      return;
    }
    const item: { caminho: string; tipo: string; valor?: unknown } = { caminho, tipo: v === null ? "null" : typeof v };
    if (!PROIBIDO.test(chave) && PERMITIDO.test(chave)) item.valor = v;
    out.push(item);
  };
  andar(obj, "", "");
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ erro: "Use POST." }, 405);
  if (!(await autorizado(req))) return json({ erro: "Sem permissão." }, 401);
  if (!QUESTAR_TOKEN) return json({ erro: "Segredo QUESTAR_API_TOKEN ausente." }, 500);
  let corpo: any = {};
  try { corpo = await req.json(); } catch { /* vazio */ }
  const placas: string[] = (Array.isArray(corpo.placas) ? corpo.placas : []).map((p: unknown) => String(p).toUpperCase().replace(/[^A-Z0-9]/g, "")).filter((p: string) => /^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$/.test(p)).slice(0, 3);
  if (!placas.length) return json({ erro: "Informe placas válidas." }, 400);

  const resultados = [];
  for (const placa of placas) {
    for (const formato of [placa, placa.slice(0, 3) + "-" + placa.slice(3)]) {
      const inicio = Date.now();
      let status = 0, texto = "";
      try {
        const resp = await fetch(QUESTAR_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": "Bearer " + QUESTAR_TOKEN },
          body: JSON.stringify({ action: { name: "api_get_data", parameters: [{ name: "license_nmbr", value: formato }] } }),
        });
        status = resp.status; texto = await resp.text();
      } catch (e) {
        resultados.push({ placa, formato, erro_rede: String(e) });
        continue;
      }
      let j: unknown = null;
      try { j = texto ? JSON.parse(texto) : null; } catch { /* não é JSON */ }
      resultados.push({
        placa, formato, http: status, ms: Date.now() - inicio, tamanho_resposta: texto.length,
        json: j !== null,
        // texto que não é JSON (ex.: mensagem de erro) só sai se for curto e sem números longos
        texto_curto: j === null && texto.length <= 300 && !/\d{6,}/.test(texto) ? texto : undefined,
        campos: j !== null ? estrutura(j) : undefined,
      });
      if (j !== null && status === 200) break; // achou com este formato; não tenta o outro
    }
  }
  return json({ acao: "api_get_data", nada_gravado: true, resultados });
});
