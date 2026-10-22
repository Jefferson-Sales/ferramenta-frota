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
class Falha extends Error { constructor(msg: string, public status = 400, public extra: Record<string, unknown> = {}) { super(msg); } }

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const normPlaca = (p: unknown) => String(p || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
// Só primeiro e último nome: confirma a identidade sem expor o nome completo a quem chuta matrículas.
function nomeCurto(n: string) {
  const partes = (n || "").trim().split(/\s+/);
  return partes.length > 1 ? partes[0] + " " + partes[partes.length - 1] : partes[0] || "";
}

// Quem está chamando: IP (do proxy da Supabase) e id aleatório do aparelho (gerado pelo checklist.html).
// Só servem para o limite de tentativas; o banco guarda apenas um código cifrado (HMAC) deles.
type Cliente = { ip: string; aparelho: string };
function clienteDe(req: Request, body: any): Cliente {
  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "";
  return { ip, aparelho: String(body?.aparelho || "").slice(0, 100) };
}
// Retirada aberta do motorista em OUTRO carro (trava de devolução), ou null.
async function devolucaoPendente(matricula: string, veiculoId: string) {
  const { data, error } = await db().rpc("retirada_pendente", { p_matricula: matricula, p_veiculo: veiculoId });
  if (error) throw error;
  const p = (data || [])[0];
  return p ? { checklist_id: p.checklist_id as string, placa: p.placa as string, enviado_em: p.enviado_em as string } : null;
}
const dataHoraBR = (iso: string) => new Date(iso).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo" }).replace(",", " às");
const horaBR = (iso: string) => new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo" });

// Limite: 5 matrículas erradas em 15 min (por aparelho ou por IP) bloqueiam por 15 min. Acerto não conta.
async function colaborador(matricula: unknown, cli: Cliente) {
  const { data: ate, error: e0 } = await db().rpc("checklist_bloqueado_ate", { p_ip: cli.ip, p_aparelho: cli.aparelho });
  if (e0) throw e0;
  if (ate && new Date(ate) > new Date())
    throw new Falha("Muitas tentativas de matrícula erradas. Tente de novo às " + horaBR(ate) + ".", 429);
  const errou = async (msg: string, status = 400, extra: Record<string, unknown> = {}): Promise<never> => {
    await db().rpc("checklist_registrar_erro", { p_ip: cli.ip, p_aparelho: cli.aparelho });
    throw new Falha(msg, status, extra);
  };
  const m = String(matricula || "").trim();
  if (!/^\d{1,10}$/.test(m)) await errou("Matrícula inválida.");
  const { data, error } = await db().rpc("buscar_colaborador", { p_matricula: m });
  if (error) throw error;
  if (!data || !data.length) {
    // sem cadastro ativo: avisa se há auto-cadastro em análise ou reprovado (continua contando como erro no limite)
    const { data: cad } = await db().rpc("cadastro_motorista_status", { p_matricula: m });
    const st = (cad || [])[0];
    if (st && st.status === "pendente")
      await errou("Seu cadastro está em análise pelo time de frota. Assim que for aprovado, você poderá fazer o checklist.", 404, { cadastro: { status: "pendente" } });
    if (st && st.status === "reprovado")
      await errou("Seu cadastro foi reprovado: " + (MOTIVOS_REPROVACAO[st.motivo_reprovacao] || "motivo não informado") + ". Corrija e envie de novo.", 404,
        { cadastro: { status: "reprovado", motivo: st.motivo_reprovacao } });
    await errou("Matrícula não encontrada ou inativa.", 404, { sem_cadastro: true });
  }
  // se a matrícula existir nas duas tabelas, prefere o motorista (tem motorista_id)
  const c = data.find((r: any) => r.origem === "motorista") || data[0];
  return { matricula: m, nome: c.nome as string, hub_id: c.hub_id, motorista_id: c.motorista_id,
           user_id: c.origem === "usuario" ? (c.user_id as string) : null };
}

// ---------------------------------------------------------------- auto-cadastro de motorista (Onda 3)
const MOTIVOS_REPROVACAO: Record<string, string> = {
  cnh_ilegivel: "CNH ilegível", cnh_vencimento: "data de vencimento da CNH", foto_cnh_ilegivel: "foto da CNH ilegível",
  data_nascimento: "data de nascimento", rg: "RG", cpf: "CPF", senha_ja_cadastrada: "senha de abastecimento já cadastrada",
  senha_fora_padrao: "senha de abastecimento fora do padrão", cadastro_duplicado: "cadastro duplicado",
};
const BUCKET_CNH = "motoristas-cnh";

async function acaoCadastroInicio() {
  const { data, error } = await db().from("hubs").select("id, nome").eq("ativo", true).order("nome");
  if (error) throw error;
  return { hubs: data || [] };
}
async function acaoCadastroUpload(body: any, cli: Cliente) {
  const { data: ate } = await db().rpc("checklist_bloqueado_ate", { p_ip: cli.ip, p_aparelho: cli.aparelho });
  if (ate && new Date(ate) > new Date()) throw new Falha("Muitas tentativas erradas. Tente de novo às " + horaBR(ate) + ".", 429);
  const id = String(body.cadastro_id || "");
  if (!UUID_RE.test(id)) throw new Falha("Cadastro inválido.");
  const { data: ja } = await db().from("motoristas_cadastros").select("id").eq("id", id).maybeSingle();
  if (ja) throw new Falha("Este cadastro já foi enviado.");
  const path = `cadastros/${id}/cnh.jpg`;
  const { data, error } = await admin.storage.from(BUCKET_CNH).createSignedUploadUrl(path, { upsert: true });
  if (error) throw error;
  return { path, signedUrl: data.signedUrl };
}
async function acaoCadastroEnviar(body: any, cli: Cliente) {
  const { data: ate } = await db().rpc("checklist_bloqueado_ate", { p_ip: cli.ip, p_aparelho: cli.aparelho });
  if (ate && new Date(ate) > new Date()) throw new Falha("Muitas tentativas erradas. Tente de novo às " + horaBR(ate) + ".", 429);
  const c = body.cadastro || {};
  const { data, error } = await db().rpc("registrar_cadastro_motorista", { p: c, p_ip: cli.ip, p_aparelho: cli.aparelho });
  if (error) throw new Falha(error.message);
  return { ok: true, id: data };
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

// Hubs liberados para quem está preenchendo. null = sem restrição.
// - auxiliar logado: os hubs dele (admin: todos);
// - matrícula de usuário do sistema (auxiliar que entrou como "Sou Motorista"): os hubs desse usuário,
//   senão bastaria não fazer login para escapar da restrição;
// - motorista (matrícula do cadastro de motoristas): sem restrição.
async function hubsLiberados(aux: any, c: { user_id: string | null }): Promise<string[] | null> {
  const uid = aux ? aux.user_id : c.user_id;
  if (!uid) return null;
  const { data: p } = await db().from("usuarios_perfil").select("papel, ativo").eq("user_id", uid).maybeSingle();
  if (p && p.ativo && p.papel === "admin") return null;
  const { data, error } = await db().from("usuarios_hubs").select("hub_id").eq("user_id", uid);
  if (error) throw error;
  return (data || []).map((r: any) => r.hub_id as string);
}
function exigirHub(hubs: string[] | null, v: { hub_id: string | null }) {
  if (hubs && !(v.hub_id && hubs.includes(v.hub_id)))
    throw new Falha("Esta placa é de um hub que não está liberado para você.", 403);
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

async function acaoIdentificar(body: any, aux: any, cli: Cliente) {
  const c = await colaborador(body.matricula, cli);
  const liberados = await hubsLiberados(aux, c);
  let qHubs = db().from("hubs").select("id, nome").eq("ativo", true).order("nome");
  if (liberados) qHubs = qHubs.in("id", liberados.length ? liberados : ["00000000-0000-0000-0000-000000000000"]);
  const [{ data: hubs, error: e1 }, { data: catalogo, error: e2 }] = await Promise.all([
    qHubs,
    db().from("checklist_itens_catalogo")
      .select("grupo, grupo_nome, grupo_ordem, codigo, descricao, tipos, severidade_padrao, subtipos, combustiveis, ordem")
      .eq("ativo", true).order("grupo_ordem").order("ordem"),
  ]);
  if (e1) throw e1; if (e2) throw e2;
  return { nome: nomeCurto(c.nome), hub_id: c.hub_id, auxiliar: !!aux, hubs, catalogo };
}

async function acaoVeiculo(body: any, aux: any, cli: Cliente) {
  const c = await colaborador(body.matricula, cli);
  const v = await veiculoPorPlaca(body.placa);
  exigirHub(await hubsLiberados(aux, c), v);

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
    // aviso antecipado da trava (só pesa se o motorista escolher Retirada)
    devolucao_pendente: await devolucaoPendente(c.matricula, v.id).then((p) => p && { placa: p.placa, enviado_em: p.enviado_em }),
  };
}

async function acaoUpload(body: any, aux: any, cli: Cliente) {
  const c = await colaborador(body.matricula, cli);
  const v = await veiculoPorPlaca(body.placa);
  exigirHub(await hubsLiberados(aux, c), v);
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

async function acaoEnviar(body: any, aux: any, cli: Cliente) {
  const c = await colaborador(body.matricula, cli);
  const ck = body.checklist || {};
  if (!["retirada", "devolucao", "inspecao_tecnica"].includes(ck.tipo)) throw new Falha("Tipo de checklist inválido.");
  if (ck.tipo === "inspecao_tecnica" && !aux) throw new Falha("Inspeção técnica exige login de auxiliar de frota.", 403);
  const v = await veiculoPorPlaca(ck.placa);
  exigirHub(await hubsLiberados(aux, c), v);
  const km = Number(ck.km);
  if (!isFinite(km) || km <= 0) throw new Falha("KM inválido.");
  // trava de devolução: Retirada de outro carro com Retirada anterior ainda aberta
  if (ck.tipo === "retirada") {
    const pend = await devolucaoPendente(c.matricula, v.id);
    if (pend) {
      await db().rpc("registrar_trava_devolucao", { p_checklist: pend.checklist_id });
      throw new Falha("Você ainda não fez a devolução do " + pend.placa + " (retirado em " + dataHoraBR(pend.enviado_em) +
        "). Faça a devolução antes de retirar outro carro.", 409, { devolucao_pendente: { placa: pend.placa, enviado_em: pend.enviado_em } });
    }
  }

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
    const cli = clienteDe(req, body);
    switch (body.acao) {
      case "sessao": return json(aux ? { auxiliar: true, nome: aux.nome, matricula: aux.matricula } : { auxiliar: false });
      case "identificar": return json(await acaoIdentificar(body, aux, cli));
      case "veiculo": return json(await acaoVeiculo(body, aux, cli));
      case "upload": return json(await acaoUpload(body, aux, cli));
      case "enviar": return json(await acaoEnviar(body, aux, cli));
      case "cadastro_inicio": return json(await acaoCadastroInicio());
      case "cadastro_upload": return json(await acaoCadastroUpload(body, cli));
      case "cadastro_enviar": return json(await acaoCadastroEnviar(body, cli));
      default: return json({ error: "Ação desconhecida." }, 400);
    }
  } catch (e) {
    const status = e instanceof Falha ? e.status : 500;
    return json({ error: (e as Error).message || String(e), ...(e instanceof Falha ? e.extra : {}) }, status);
  }
});
