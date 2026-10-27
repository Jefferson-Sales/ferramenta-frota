// Edge Function `backfill-questar` — D4b: carga retroativa da telemetria Questar dos elétricos.
// Separada da `sync-telemetria-questar` (cron diário) de propósito: não arrisca a rotina que já roda.
//
// Chamada (POST JSON): { modo: "teste" | "gravar", de: "AAAA-MM-DD", ate: "AAAA-MM-DD", placas?: [..], max_veiculos?: n }
//   - teste:  consulta a API e devolve um RESUMO (nenhuma escrita; sem coordenadas nem nomes na resposta)
//   - gravar: grava em frota.telemetria_viagens (upsert por drive_id → rodar de novo não duplica) e
//             recalcula frota.telemetria_diaria (km do dia = soma das viagens; hodômetro do fim de cada dia).
//             Nunca mexe em veiculos.km_atual e nunca sobrescreve dia gravado pela sincronização diária.
// Janela de no máximo 32 dias (limite da API). Para em ~110 s e devolve as placas que faltaram (retomar depois).
// Permissão: chave interna x-automation-key (Vault `automation_secret_questar`) ou JWT de admin ativo.
// Privacidade: latitude/longitude, endereços e nome do motorista são descartados na leitura.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const QUESTAR_TOKEN = Deno.env.get("QUESTAR_API_TOKEN");
const QUESTAR_URL = "https://app.questar.io/v2/questar-units/api";
const LIMITE_TEMPO_MS = 110_000;
const PAUSA_ENTRE_CHAMADAS_MS = 400;
const TZ = "America/Sao_Paulo";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

function withCors(resp: Response) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Headers", "authorization, content-type, apikey, x-automation-key");
  resp.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return resp;
}
function json(body: unknown, status = 200) {
  return withCors(new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } }));
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function autorizar(req: Request) {
  const chave = req.headers.get("x-automation-key") || "";
  if (chave) {
    const { data, error } = await db().rpc("verificar_automation_key", { chave });
    if (!error && data === true) return;
  }
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) throw new Falha("Sem autenticação.", 401);
  const { data: u, error } = await admin.auth.getUser(jwt);
  if (error || !u?.user) throw new Falha("Sessão inválida.", 401);
  const { data: p } = await db().from("usuarios_perfil").select("papel, ativo").eq("user_id", u.user.id).maybeSingle();
  if (!p || !p.ativo || p.papel !== "admin") throw new Falha("Só admin pode rodar o backfill.", 403);
}

// Chamada à Questar com novas tentativas em erro temporário (429/5xx/rede): 2 s, 4 s, 8 s.
async function questar(parametros: { name: string; value: string }[]) {
  for (let tentativa = 0; ; tentativa++) {
    try {
      const resp = await fetch(QUESTAR_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": "Bearer " + QUESTAR_TOKEN },
        body: JSON.stringify({ action: { name: "get_vehicle_trips_extended", parameters: parametros } }),
      });
      const texto = await resp.text();
      let corpo: any = null;
      try { corpo = texto ? JSON.parse(texto) : null; } catch { corpo = null; }
      if ((resp.status === 429 || resp.status >= 500) && tentativa < 3) { await espera(2000 * 2 ** tentativa); continue; }
      return { status: resp.status, corpo };
    } catch (e) {
      if (tentativa < 3) { await espera(2000 * 2 ** tentativa); continue; }
      throw e;
    }
  }
}

const dec = (v: any) => { if (v == null) return ""; try { return decodeURIComponent(String(v)); } catch { return String(v); } };
const num = (v: any) => { const n = parseFloat(dec(v)); return isNaN(n) ? null : n; };
// duração vem como "HH:MM:SS" (url-encoded, ex.: "02%3A15%3A00") → segundos
const segundos = (v: any) => { const p = dec(v).split(":").map(Number); return p.length === 3 && p.every((x) => !isNaN(x)) ? p[0] * 3600 + p[1] * 60 + p[2] : null; };

// "AAAA-MM-DDTHH:MM:SS" da Questar, sem fuso. CONFIRMADO EM 27/10/2026: é UTC (às 10:50 de Brasília a viagem
// mais recente terminava "13:50"). O dia gravado é o dia de Brasília do fim da viagem.
function instante(texto: string, fuso: string) {
  const t = dec(texto).replace(" ", "T");
  if (!t) return null;
  const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(t) ? t : t + fuso);
  return isNaN(d.getTime()) ? null : d;
}
const diaBrasilia = (d: Date) => d.toLocaleDateString("en-CA", { timeZone: TZ });

// Todas as viagens de uma placa na janela, seguindo a paginação (has_more).
async function viagensDaPlaca(placa: string, de: string, ate: string) {
  let pagina = 1, reinicios = 0, paginas = 0;
  const todas: any[] = [];
  for (;;) {
    const r = await questar([
      { name: "license_number", value: placa },
      { name: "from_date", value: de },
      { name: "to_date", value: ate },
      { name: "page_number", value: String(pagina) },
      { name: "page_size", value: "2000" },
    ]);
    const props = r.corpo?.response?.properties;
    if (r.status !== 200 || !props) throw new Falha("Questar respondeu " + r.status + " para " + placa);
    if (String(props.action_value) === "3" && /expired/i.test(String(props.description)) && reinicios < 1) {
      reinicios++; pagina = 1; todas.length = 0; continue;            // sessão da paginação venceu: recomeça
    }
    if (String(props.action_value) !== "0" && !Array.isArray(props.data)) {
      throw new Falha("Questar: " + (props.description || "erro " + props.action_value) + " (" + placa + ")");
    }
    paginas++;
    for (const t of (props.data || [])) todas.push(t);
    if (!props.pagination?.has_more) break;
    pagina++;
    await espera(PAUSA_ENTRE_CHAMADAS_MS);
  }
  return { viagens: todas, paginas };
}

// Só os campos que guardamos (sem coordenadas, endereços nem nomes).
function limpar(t: any, veiculoId: string, fuso: string) {
  const ini = instante(t.start_time, fuso), fim = instante(t.end_time, fuso);
  const ref = fim || ini;
  if (!ref || t.drive_id == null) return null;
  const dist = num(t.distance), hodFim = num(t.total_mileage);
  let hodIni = num(t.start_mileage);
  if (hodIni == null && hodFim != null && dist != null) hodIni = hodFim - dist;
  return {
    drive_id: Number(dec(t.drive_id)), veiculo_id: veiculoId,
    questar_vehicle_id: t.vehicle_id != null ? dec(t.vehicle_id) : null,
    driver_code: t.driver_code ? dec(t.driver_code) : null,
    inicio: ini ? ini.toISOString() : null, fim: fim ? fim.toISOString() : null, dia: diaBrasilia(ref),
    distancia_km: dist, hodometro_inicio: hodIni, hodometro_fim: hodFim,
    duracao_seg: segundos(t.drive_duration),
    nivel_inicio_pct: num(t.start_fuel_level_percent), nivel_fim_pct: num(t.end_fuel_level_percent),
    energy_type: t.energy_type ? dec(t.energy_type) : null, fonte: "questar_backfill",
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return withCors(new Response(null, { status: 204 }));
  const t0 = Date.now();
  try {
    if (!QUESTAR_TOKEN) throw new Falha("QUESTAR_API_TOKEN não configurado.", 500);
    await autorizar(req);
    const b = await req.json().catch(() => ({}));
    const modo = b.modo === "gravar" ? "gravar" : "teste";
    const de = String(b.de || ""), ate = String(b.ate || ""), fuso = String(b.fuso || "Z");
    if (!/^\d{4}-\d\d-\d\d$/.test(de) || !/^\d{4}-\d\d-\d\d$/.test(ate) || ate < de) throw new Falha("Informe de/ate (AAAA-MM-DD).");
    const dias = (Date.parse(ate) - Date.parse(de)) / 86400000 + 1;
    if (dias > 32) throw new Falha("Janela de no máximo 32 dias (limite da Questar).");

    let q = db().from("veiculos").select("id, placa").eq("tipo_combustivel", "eletrico").eq("ativo", true).order("placa");
    const { data: todos, error } = await q;
    if (error) throw error;
    let alvo = (todos || []) as { id: string; placa: string }[];
    if (Array.isArray(b.placas) && b.placas.length) alvo = alvo.filter((v) => b.placas.includes(v.placa));
    if (b.max_veiculos) alvo = alvo.slice(0, Number(b.max_veiculos));

    const resultado: any[] = [], faltaram: string[] = [];
    let totalViagens = 0;
    for (const v of alvo) {
      if (Date.now() - t0 > LIMITE_TEMPO_MS) { faltaram.push(v.placa); continue; }
      try {
        const { viagens, paginas } = await viagensDaPlaca(v.placa, de, ate);
        const limpas = viagens.map((t) => limpar(t, v.id, fuso)).filter(Boolean) as any[];
        totalViagens += limpas.length;
        const porDia: Record<string, { km: number; hod: number | null; n: number }> = {};
        for (const l of limpas) {
          const d = porDia[l.dia] || (porDia[l.dia] = { km: 0, hod: null, n: 0 });
          d.km += l.distancia_km || 0; d.n++;
          if (l.hodometro_fim != null && (d.hod == null || l.hodometro_fim > d.hod)) d.hod = l.hodometro_fim;
        }
        const item: any = { placa: v.placa, viagens: limpas.length, paginas, dias_com_viagem: Object.keys(porDia).length,
                            km: Math.round(Object.values(porDia).reduce((s, d) => s + d.km, 0) * 10) / 10 };

        if (modo === "teste") {
          // Para conferir o formato sem expor dados pessoais: nomes dos campos e 3 viagens só com campos seguros.
          item.campos_da_api = viagens[0] ? Object.keys(viagens[0]).sort() : [];
          item.amostra = viagens.slice(0, 3).map((t) => ({
            drive_id: t.drive_id, start_time: dec(t.start_time), end_time: dec(t.end_time), distance: t.distance,
            start_mileage: t.start_mileage, total_mileage: t.total_mileage, drive_duration: t.drive_duration,
            start_fuel_level_percent: t.start_fuel_level_percent, end_fuel_level_percent: t.end_fuel_level_percent,
            energy_type: dec(t.energy_type), tem_driver_code: !!t.driver_code }));
          const horas: Record<string, number> = {};
          for (const t of viagens) { const h = dec(t.start_time).slice(11, 13); if (h) horas[h] = (horas[h] || 0) + 1; }
          item.inicio_por_hora_texto_api = horas;   // para confirmar o fuso: a operação começa de manhã
          item.niveis_preenchidos = viagens.filter((t) => num(t.start_fuel_level_percent) != null).length;
          item.ultimo_fim_texto_api = viagens.reduce((m: string, t: any) => { const e = dec(t.end_time); return e > m ? e : m; }, "");
          item.agora_utc = new Date().toISOString();
          item.amostra_limpa = limpas.slice(0, 2).map((l) => ({ drive_id: l.drive_id, inicio: l.inicio, fim: l.fim, dia: l.dia, km: l.distancia_km, duracao_seg: l.duracao_seg, hod_fim: l.hodometro_fim }));
        } else {
          for (let i = 0; i < limpas.length; i += 500) {
            const { error: e1 } = await db().from("telemetria_viagens").upsert(limpas.slice(i, i + 500), { onConflict: "drive_id" });
            if (e1) throw e1;
          }
          // dias já gravados pela sincronização diária (fonte questar_api) não são sobrescritos
          const { data: existentes, error: e2 } = await db().from("telemetria_diaria").select("data, fonte")
            .eq("veiculo_id", v.id).in("data", Object.keys(porDia).length ? Object.keys(porDia) : ["1900-01-01"]);
          if (e2) throw e2;
          const protegidos = new Set((existentes || []).filter((x: any) => x.fonte !== "questar_backfill").map((x: any) => x.data));
          // O dia é recalculado com TODAS as viagens já gravadas daquele carro/dia (não só as desta consulta):
          // a API filtra por data UTC, então um dia de Brasília pode vir dividido entre duas janelas.
          const diasTocados = Object.keys(porDia).filter((d) => !protegidos.has(d));
          const totais: Record<string, { km: number; hod: number | null }> = {};
          for (let i = 0; i < diasTocados.length; i += 100) {
            const { data: vg, error: e4 } = await db().from("telemetria_viagens").select("dia, distancia_km, hodometro_fim")
              .eq("veiculo_id", v.id).in("dia", diasTocados.slice(i, i + 100));
            if (e4) throw e4;
            for (const x of (vg || []) as any[]) {
              const t = totais[x.dia] || (totais[x.dia] = { km: 0, hod: null });
              t.km += Number(x.distancia_km) || 0;
              if (x.hodometro_fim != null && (t.hod == null || Number(x.hodometro_fim) > t.hod)) t.hod = Number(x.hodometro_fim);
            }
          }
          const linhas = diasTocados.map((d) => ({
            veiculo_id: v.id, data: d, km_rodado: Math.round((totais[d] ? totais[d].km : porDia[d].km) * 10) / 10,
            km_hodometro_fim: totais[d] ? totais[d].hod : porDia[d].hod, fonte: "questar_backfill" }));
          if (linhas.length) {
            const { error: e3 } = await db().from("telemetria_diaria").upsert(linhas, { onConflict: "veiculo_id,data" });
            if (e3) throw e3;
          }
          item.dias_gravados = linhas.length; item.dias_preservados = protegidos.size;
        }
        resultado.push(item);
      } catch (e) {
        resultado.push({ placa: v.placa, erro: (e as Error).message || String(e) });
      }
      await espera(PAUSA_ENTRE_CHAMADAS_MS);
    }
    return json({ modo, de, ate, fuso, veiculos: alvo.length, viagens: totalViagens, faltaram, segundos: Math.round((Date.now() - t0) / 1000), resultado });
  } catch (e) {
    const status = e instanceof Falha ? e.status : 500;
    return json({ error: (e as Error).message || String(e) }, status);
  }
});
