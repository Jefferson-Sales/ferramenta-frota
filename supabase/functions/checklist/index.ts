// Edge Function `checklist` — backend do formulário mobile (checklist.html).
// Motoristas usam SEM login: cada chamada traz a matrícula, validada no banco.
// Auxiliares de frota podem mandar o JWT (Authorization) e só eles fazem Inspeção técnica.
// verify_jwt = false na plataforma (preflight CORS); a validação é feita aqui dentro.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "checklist-fotos";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
const db = () => admin.schema("frota");

function withCors(resp: Response) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Headers", "authorization, content-type, apikey, x-client-info");
  resp.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return resp;
}
function json(body: unknown, status = 200) {
  return withCors(new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } }));
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const normPlaca = (p: unknown) => String(p || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
// Só primeiro e último nome: confirma a identidade sem expor o nome completo a quem chuta matrículas.
function nomeCurto(n: string) {
  const partes = (n || "").trim().split(/\s+/);
  return partes.length > 1 ? partes[0] + " " + partes[partes.length - 1] : partes[0] || "";
}

async function colaborador(matricula: unknown) {
  const m = String(matricula || "").trim();
  if (!/^\d{1,10}$/.test(m)) throw new Falha("Matrícula inválida.");
  const { data, error } = await db().rpc("buscar_colaborador", { p_matricula: m });
  if (error) throw error;
  if (!data || !data.length) throw new Falha("Matrícula não encontrada ou inativa.", 404);
  // se a matrícula existir nas duas tabelas, prefere o motorista (tem motorista_id)
  const c = data.find((r: any) => r.origem === "motorista") || data[0];
  return { matricula: m, nome: c.nome as string, hub_id: c.hub_id, motorista_id: c.motorista_id };
}

// Auxiliar de frota logado: admin, ou operador com módulo checklist/manutenção.
async function auxiliarLogado(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data?.user) return null;
  const { data: p } = await db().from("usuarios_perfil")
    .select("user_id, nome, papel, modulos_operador, matricula, ativo").eq("user_id", data.user.id).maybeSingle();
  if (!p || !p.ativo) return null;
  const mods: string[] = p.modulos_operador || [];
  const ok = p.papel === "admin" || (p.papel === "operador" && (mods.includes("checklist") || mods.includes("manutencao")));
  return ok ? { user_id: p.user_id as string, nome: p.nome as string, matricula: p.matricula as string | null } : null;
}

async function veiculoPorPlaca(placa: unknown) {
  const pl = normPlaca(placa);
  if (pl.length !== 7) throw new Falha("Placa inválida.");
  const { data, error } = await db().from("veiculos")
    .select("id, placa, modelo, hub_id, tipo_combustivel, km_atual").eq("placa", pl).eq("ativo", true).maybeSingle();
  if (error) throw error;
  if (!data) throw new Falha("Placa não encontrada na frota ativa.", 404);
  return data;
}

async function acaoIdentificar(body: any, aux: any) {
  const c = await colaborador(body.matricula);
  const [{ data: hubs, error: e1 }, { data: catalogo, error: e2 }] = await Promise.all([
    db().from("hubs").select("id, nome").eq("ativo", true).order("nome"),
    db().from("checklist_itens_catalogo")
      .select("grupo, grupo_nome, grupo_ordem, codigo, descricao, tipos, severidade_padrao, subtipos, combustiveis, ordem")
      .eq("ativo", true).order("grupo_ordem").order("ordem"),
  ]);
  if (e1) throw e1; if (e2) throw e2;
  return { nome: nomeCurto(c.nome), hub_id: c.hub_id, auxiliar: !!aux, hubs, catalogo };
}

async function acaoVeiculo(body: any) {
  await colaborador(body.matricula);
  const v = await veiculoPorPlaca(body.placa);

  const { data: ult } = await db().from("checklists")
    .select("id, tipo, km, nivel_combustivel, bateria_pct, enviado_em, resultado, checklist_grupos(grupo, tem_anomalia)")
    .eq("veiculo_id", v.id).eq("status", "enviado").order("enviado_em", { ascending: false }).limit(1).maybeSingle();

  const { data: abertas, error } = await db().from("checklist_anomalias")
    .select("id, grupo, item_codigo, subtipo, descricao, severidade, status, created_at, checklist_fotos(storage_path)")
    .eq("veiculo_id", v.id).eq("nova", true).in("status", ["aberta", "em_reparo"]).order("created_at");
  if (error) throw error;

  // links temporários (1h) para a foto original de cada anomalia aberta
  const paths = (abertas || []).map((a: any) => a.checklist_fotos?.[0]?.storage_path).filter(Boolean);
  const urls: Record<string, string> = {};
  if (paths.length) {
    const { data: signed } = await admin.storage.from(BUCKET).createSignedUrls(paths, 3600);
    (signed || []).forEach((s: any) => { if (s.signedUrl) urls[s.path] = s.signedUrl; });
  }
  const anomalias = (abertas || []).map((a: any) => {
    const p = a.checklist_fotos?.[0]?.storage_path;
    return { id: a.id, grupo: a.grupo, item_codigo: a.item_codigo, subtipo: a.subtipo, descricao: a.descricao,
             severidade: a.severidade, status: a.status, reportada_em: a.created_at, foto_url: p ? urls[p] || null : null };
  });

  return {
    veiculo: v,
    ultimo: ult ? { tipo: ult.tipo, km: ult.km, nivel_combustivel: ult.nivel_combustivel, bateria_pct: ult.bateria_pct,
                    enviado_em: ult.enviado_em, resultado: ult.resultado, grupos: ult.checklist_grupos || [] } : null,
    tipo_sugerido: ult && ult.tipo === "retirada" ? "devolucao" : "retirada",
    anomalias_abertas: anomalias,
  };
}

async function acaoUpload(body: any) {
  await colaborador(body.matricula);
  const v = await veiculoPorPlaca(body.placa);
  const cid = String(body.checklist_id || "");
  const arq = String(body.arquivo || "");
  if (!UUID_RE.test(cid)) throw new Falha("Checklist inválido.");
  if (!/^[a-z0-9_-]{1,60}\.jpg$/.test(arq)) throw new Falha("Nome de arquivo inválido.");
  const { data: ja } = await db().from("checklists").select("status").eq("id", cid).maybeSingle();
  if (ja) throw new Falha("Este checklist já foi enviado.");
  const path = `${v.placa}/${cid}/${arq}`;
  const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(path, { upsert: true });
  if (error) throw error;
  return { path, signedUrl: data.signedUrl };
}

async function acaoEnviar(body: any, aux: any) {
  const c = await colaborador(body.matricula);
  const ck = body.checklist || {};
  if (!["retirada", "devolucao", "inspecao_tecnica"].includes(ck.tipo)) throw new Falha("Tipo de checklist inválido.");
  if (ck.tipo === "inspecao_tecnica" && !aux) throw new Falha("Inspeção técnica exige login de auxiliar de frota.", 403);
  const v = await veiculoPorPlaca(ck.placa);
  const km = Number(ck.km);
  if (!isFinite(km) || km <= 0) throw new Falha("KM inválido.");

  const payload = {
    ...ck,
    veiculo_id: v.id,
    km,
    colaborador_matricula: c.matricula,
    colaborador_nome: c.nome, // nome completo vem do banco, nunca do celular
  };
  const { data, error } = await db().rpc("registrar_checklist", {
    p: payload, p_preenchido_por: aux ? aux.user_id : null, p_motorista_id: c.motorista_id,
  });
  if (error) throw new Falha(error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return withCors(new Response(null, { status: 204 }));
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const aux = await auxiliarLogado(req);
    switch (body.acao) {
      case "sessao": return json(aux ? { auxiliar: true, nome: aux.nome, matricula: aux.matricula } : { auxiliar: false });
      case "identificar": return json(await acaoIdentificar(body, aux));
      case "veiculo": return json(await acaoVeiculo(body));
      case "upload": return json(await acaoUpload(body));
      case "enviar": return json(await acaoEnviar(body, aux));
      default: return json({ error: "Ação desconhecida." }, 400);
    }
  } catch (e) {
    const status = e instanceof Falha ? e.status : 500;
    return json({ error: (e as Error).message || String(e) }, status);
  }
});
