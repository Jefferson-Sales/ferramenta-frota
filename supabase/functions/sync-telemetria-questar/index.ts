// Edge Function `sync-telemetria-questar` — sincronização diária da telemetria Questar dos elétricos.
// Cron `sync-telemetria-questar-diario` (02:00 BRT, { mode: "sync", days: 2 }) e botões do card de telemetria.
//
// D4c (27/10/2026) — mesma leitura da `backfill-questar`, que já foi conferida:
//   - os horários da Questar vêm em UTC sem marcador; o dia gravado é o dia de BRASÍLIA do fim da viagem
//     (antes, viagem das 21h–24h caía no dia seguinte);
//   - hodômetro do fim de CADA dia (antes, todos os dias recebiam o hodômetro da última viagem da janela);
//   - segue a paginação (has_more) e grava cada viagem em frota.telemetria_viagens (upsert por drive_id);
//   - o km do dia é recalculado com TODAS as viagens gravadas daquele carro/dia (a API filtra por data UTC,
//     então um dia de Brasília pode chegar dividido entre duas execuções).
//   - veiculos.km_atual continua recebendo o hodômetro da viagem mais recente.
// Modos (POST JSON):
//   diag: { mode: "diag", days?, sample_size?, plates? } → resumo SEM dados pessoais nem localização, nada gravado.
//   sync: { mode: "sync", days? (1–10) } ou { mode: "sync", de, ate } (reprocessar até 32 dias; só automação/admin).
// Permissão: chave interna x-automation-key (Vault `automation_secret_questar`), admin ativo ou operador ativo
// do Cadastro da Frota. Privacidade: latitude/longitude, endereços e nome do motorista são descartados na leitura.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const QUESTAR_TOKEN = Deno.env.get("QUESTAR_API_TOKEN");
const QUESTAR_URL = "https://app.questar.io/v2/questar-units/api";
const LIMITE_TEMPO_MS = 130_000;
const PAUSA_ENTRE_CHAMADAS_MS = 300;
const TZ = "America/Sao_Paulo";
const FONTE = "questar_api";

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

// Devolve "automacao", "admin" ou "operador".
async function autorizar(req: Request) {
  const chave = req.headers.get("x-automation-key") || "";
  if (chave) {
    const { data, error } = await db().rpc("verificar_automation_key", { chave });
    if (!error && data === true) return "automacao";
  }
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) throw new Falha("Sem token de autenticação.", 401);
  const { data: u, error } = await admin.auth.getUser(jwt);
  if (error || !u?.user) throw new Falha("Token inválido ou expirado.", 401);
  const { data: p, error: e2 } = await db().from("usuarios_perfil").select("papel, ativo, modulos_operador")
    .eq("user_id", u.user.id).maybeSingle();
  if (e2) throw e2;
  if (p && p.ativo && p.papel === "admin") return "admin";
  if (p && p.ativo && (p.modulos_operador || []).includes("frota")) return "operador";
  throw new Falha("Acesso restrito a quem edita o módulo Cadastro da Frota.", 403);
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
const segundos = (v: any) => { const p = dec(v).split(":").map(Number); return p.length === 3 && p.every((x) => !isNaN(x)) ? p[0] * 3600 + p[1] * 60 + p[2] : null; };
// Texto da Questar sem fuso = UTC (confirmado em 27/10/2026).
function instante(texto: any) {
  const t = dec(texto).replace(" ", "T");
  if (!t) return null;
  const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(t) ? t : t + "Z");
  return isNaN(d.getTime()) ? null : d;
}
const diaBrasilia = (d: Date) => d.toLocaleDateString("en-CA", { timeZone: TZ });

async function viagensDaPlaca(placa: string, de: string, ate: string) {
  let pagina = 1, reinicios = 0;
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
    if (r.status !== 200 || !props) throw new Falha("Questar respondeu " + r.status);
    if (String(props.action_value) === "3" && /expired/i.test(String(props.description)) && reinicios < 1) {
      reinicios++; pagina = 1; todas.length = 0; continue;
    }
    if (String(props.action_value) !== "0" && !Array.isArray(props.data)) {
      throw new Falha("Questar: " + (props.description || "erro " + props.action_value));
    }
    for (const t of (props.data || [])) todas.push(t);
    if (!props.pagination?.has_more) break;
    pagina++;
    await espera(PAUSA_ENTRE_CHAMADAS_MS);
  }
  return todas;
}

// Só os campos que guardamos (sem coordenadas, endereços nem nomes).
function limpar(t: any, veiculoId: string) {
  const ini = instante(t.start_time), fim = instante(t.end_time);
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
    energy_type: t.energy_type ? dec(t.energy_type) : null, fonte: FONTE, sincronizado_em: new Date().toISOString(),
  };
}

// Grava as viagens e recalcula os dias tocados a partir de TODAS as viagens gravadas do carro naquele dia.
async function gravar(veiculoId: string, limpas: any[]) {
  for (let i = 0; i < limpas.length; i += 500) {
    const { error } = await db().from("telemetria_viagens").upsert(limpas.slice(i, i + 500), { onConflict: "drive_id" });
    if (error) throw error;
  }
  let dias = [...new Set(limpas.map((l) => l.dia))];
  if (!dias.length) return 0;
  // dia lançado por outra fonte (ex.: manual) não é sobrescrito
  const { data: existentes, error: e2 } = await db().from("telemetria_diaria").select("data, fonte")
    .eq("veiculo_id", veiculoId).in("data", dias);
  if (e2) throw e2;
  const protegidos = new Set((existentes || []).filter((x: any) => !String(x.fonte || "").startsWith("questar_")).map((x: any) => x.data));
  dias = dias.filter((d) => !protegidos.has(d));
  if (!dias.length) return 0;
  const totais: Record<string, { km: number; hod: number | null }> = {};
  const { data: vg, error: e3 } = await db().from("telemetria_viagens").select("dia, distancia_km, hodometro_fim")
    .eq("veiculo_id", veiculoId).in("dia", dias);
  if (e3) throw e3;
  for (const x of (vg || []) as any[]) {
    const t = totais[x.dia] || (totais[x.dia] = { km: 0, hod: null });
    t.km += Number(x.distancia_km) || 0;
    if (x.hodometro_fim != null && (t.hod == null || Number(x.hodometro_fim) > t.hod)) t.hod = Number(x.hodometro_fim);
  }
  const linhas = dias.filter((d) => totais[d]).map((d) => ({
    veiculo_id: veiculoId, data: d, km_rodado: Math.round(totais[d].km * 10) / 10,
    km_hodometro_fim: totais[d].hod, fonte: FONTE }));
  if (linhas.length) {
    const { error } = await db().from("telemetria_diaria").upsert(linhas, { onConflict: "veiculo_id,data" });
    if (error) throw error;
  }
  return linhas.length;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return withCors(new Response(null, { status: 204 }));
  const t0 = Date.now();
  try {
    if (!QUESTAR_TOKEN) throw new Falha("QUESTAR_API_TOKEN não configurado nos secrets da função.", 500);
    const quem = await autorizar(req);
    const b = await req.json().catch(() => ({}));
    const mode = b.mode === "sync" ? "sync" : "diag";

    // Janela. A API filtra por data UTC; começar pela data de Brasília cobre o dia de Brasília inteiro
    // (00:00 BRT = 03:00 UTC do mesmo dia). O fim é a data UTC de agora (pode já ser "amanhã" em UTC).
    const agora = new Date();
    let de: string, ate: string;
    if (b.de || b.ate) {
      if (quem === "operador") throw new Falha("Reprocessar por datas é só para admin.", 403);
      de = String(b.de || ""); ate = String(b.ate || "");
      if (!/^\d{4}-\d\d-\d\d$/.test(de) || !/^\d{4}-\d\d-\d\d$/.test(ate) || ate < de) throw new Falha("Informe de/ate (AAAA-MM-DD).");
      if ((Date.parse(ate) - Date.parse(de)) / 86400000 + 1 > 32) throw new Falha("Janela de no máximo 32 dias (limite da Questar).");
    } else {
      const days = Math.min(Math.max(Number(b.days) || 2, 1), 10);
      de = diaBrasilia(new Date(agora.getTime() - days * 86400000));
      ate = agora.toISOString().slice(0, 10);
    }

    const { data: veiculos, error } = await db().from("veiculos").select("id, placa, km_atual")
      .eq("tipo_combustivel", "eletrico").eq("ativo", true).order("placa");
    if (error) throw error;
    let alvo = (veiculos || []) as { id: string; placa: string; km_atual: number | null }[];
    if (Array.isArray(b.plates) && b.plates.length) alvo = alvo.filter((v) => b.plates.includes(v.placa));

    if (mode === "diag") {
      const amostra = alvo.slice(0, Math.min(Number(b.sample_size) || 1, 5));
      const resultados = [];
      for (const v of amostra) {
        try {
          const viagens = await viagensDaPlaca(v.placa, de, ate);
          const limpas = viagens.map((t) => limpar(t, v.id)).filter(Boolean) as any[];
          const porDia: Record<string, { viagens: number; km: number; hodometro_fim: number | null }> = {};
          for (const l of limpas) {
            const d = porDia[l.dia] || (porDia[l.dia] = { viagens: 0, km: 0, hodometro_fim: null });
            d.viagens++; d.km = Math.round((d.km + (l.distancia_km || 0)) * 10) / 10;
            if (l.hodometro_fim != null && (d.hodometro_fim == null || l.hodometro_fim > d.hodometro_fim)) d.hodometro_fim = l.hodometro_fim;
          }
          resultados.push({ placa: v.placa, viagens: limpas.length, por_dia_brasilia: porDia,
            campos_da_api: viagens[0] ? Object.keys(viagens[0]).sort() : [] });
        } catch (e) {
          resultados.push({ placa: v.placa, erro: (e as Error).message || String(e) });
        }
      }
      return json({ mode, de, ate, total_veiculos_eletricos: (veiculos || []).length,
        aviso: "Resumo sem localização nem nome de motorista. Nada foi gravado.", resultados });
    }

    // mode === "sync"
    let processados = 0, viagensGravadas = 0, diasGravados = 0;
    const erros: any[] = [], faltaram: string[] = [];
    for (const v of alvo) {
      if (Date.now() - t0 > LIMITE_TEMPO_MS) { faltaram.push(v.placa); continue; }
      try {
        const viagens = await viagensDaPlaca(v.placa, de, ate);
        const limpas = viagens.map((t) => limpar(t, v.id)).filter(Boolean) as any[];
        diasGravados += await gravar(v.id, limpas);
        viagensGravadas += limpas.length;
        // hodômetro atual = o da viagem mais recente
        let ultima: any = null;
        for (const l of limpas) if (l.hodometro_fim != null && l.fim && (!ultima || l.fim > ultima.fim)) ultima = l;
        if (ultima && ultima.hodometro_fim !== v.km_atual) {
          const { error: e } = await db().from("veiculos").update({ km_atual: ultima.hodometro_fim }).eq("id", v.id);
          if (e) throw e;
        }
        processados++;
      } catch (e) {
        erros.push({ placa: v.placa, erro: (e as Error).message || String(e) });
      }
      await espera(PAUSA_ENTRE_CHAMADAS_MS);
    }
    return json({ mode, de, ate, processados, total: alvo.length, viagens: viagensGravadas, dias_gravados: diasGravados,
      erros, faltaram, segundos: Math.round((Date.now() - t0) / 1000) });
  } catch (e) {
    const status = e instanceof Falha ? e.status : 400;
    return json({ error: (e as Error).message || String(e) }, status);
  }
});
