// Edge Function `usuarios` — Gerenciar acessos (tela só para admin no index.html).
// Cria login (exige service_role, por isso fica aqui e não no navegador), edita perfil,
// ativa/desativa acesso. Toda chamada exige o JWT de um usuário com papel 'admin' e ativo,
// conferido aqui no servidor. verify_jwt = false na plataforma (preflight CORS).
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

// módulos que existem no perfil ("qualidade" é derivado de checklist/manutencao, não entra aqui)
// "executivo" = Visão Executiva (Diretoria): só Visualizador, só "vê" (admin já vê tudo).
const MODULOS = ["executivo", "frota", "manutencao", "checklist", "multas", "financeiro", "eletrificacao"];
const PAPEIS = ["admin", "operador", "visualizador"];
const BAN_DESATIVADO = "876000h"; // ~100 anos; "none" remove o bloqueio

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
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Quem chama precisa ser admin ativo. Devolve o user_id dele.
async function exigirAdmin(req: Request): Promise<string> {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) throw new Falha("Faça login.", 401);
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data?.user) throw new Falha("Sessão inválida ou expirada. Faça login novamente.", 401);
  const { data: p, error: e2 } = await db().from("usuarios_perfil")
    .select("papel, ativo").eq("user_id", data.user.id).maybeSingle();
  if (e2) throw e2;
  if (!p || !p.ativo || p.papel !== "admin") throw new Falha("Apenas administradores podem gerenciar acessos.", 403);
  return data.user.id;
}

function gerarSenha(): string {
  // sem caracteres ambíguos (0/O, 1/l/I)
  const letras = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ", digitos = "23456789";
  const todos = letras + digitos;
  for (;;) {
    const buf = new Uint32Array(12);
    crypto.getRandomValues(buf);
    const s = Array.from(buf, (n) => todos[n % todos.length]).join("");
    if (/\d/.test(s) && /[a-z]/.test(s) && /[A-Z]/.test(s)) return s;
  }
}

function limparModulos(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  const set = new Set(v.map((x) => String(x)));
  for (const m of set) if (!MODULOS.includes(m)) throw new Falha("Módulo desconhecido: " + m);
  return MODULOS.filter((m) => set.has(m));
}

// Monta os campos do perfil a partir do formulário, já normalizados.
async function camposPerfil(body: any, userId: string | null) {
  const nome = String(body.nome || "").trim();
  if (!nome) throw new Falha("Informe o nome.");
  if (nome.length > 120) throw new Falha("Nome muito longo.");
  const papel = String(body.papel || "");
  if (!PAPEIS.includes(papel)) throw new Falha("Papel inválido.");
  let operador = limparModulos(body.modulos_operador);
  let visualizacao = limparModulos(body.modulos_visualizacao);
  if (papel === "operador" && (visualizacao.includes("executivo") || operador.includes("executivo")))
    throw new Falha("Visão Executiva é só para o papel Visualizador (Diretoria). Admin já vê.");
  operador = operador.filter((m) => m !== "executivo");                  // ninguém "opera" a Visão Executiva
  if (papel === "admin") { operador = []; visualizacao = []; }          // admin vê e opera tudo
  else if (papel === "visualizador") operador = [];                      // visualizador não opera
  else visualizacao = MODULOS.filter((m) => visualizacao.includes(m) || operador.includes(m)); // quem opera também vê

  const mat = String(body.matricula ?? "").trim();
  let matricula: string | null = null;
  if (mat) {
    if (!/^\d{1,10}$/.test(mat)) throw new Falha("Matrícula deve ter só números.");
    let q = db().from("usuarios_perfil").select("nome").eq("matricula", mat);
    if (userId) q = q.neq("user_id", userId);
    const { data: dupU, error: e1 } = await q.limit(1);
    if (e1) throw e1;
    if (dupU && dupU.length) throw new Falha("Essa matrícula já está em uso por " + dupU[0].nome + ".");
    // só a contagem: nenhum dado do motorista sai daqui
    const { count, error: e2 } = await db().from("motoristas")
      .select("id", { count: "exact", head: true }).eq("matricula", mat).eq("ativo", true);
    if (e2) throw e2;
    if (count) throw new Falha("Essa matrícula pertence a um motorista ativo. Use a matrícula do próprio usuário.");
    matricula = mat;
  }
  return { nome, papel, modulos_operador: operador, modulos_visualizacao: visualizacao, matricula };
}

// Hubs valem só para Manutenções e Qualidade da Frota (checklist). Admin vê todos.
const MODULOS_COM_HUB = ["manutencao", "checklist"];
function usaHub(perfil: { papel: string; modulos_visualizacao: string[]; modulos_operador: string[] }) {
  if (perfil.papel === "admin") return false;
  return MODULOS_COM_HUB.some((m) => perfil.modulos_visualizacao.includes(m) || perfil.modulos_operador.includes(m));
}
async function validarHubs(v: unknown): Promise<string[]> {
  if (!Array.isArray(v)) return [];
  const ids = [...new Set(v.map((x) => String(x)))];
  for (const id of ids) if (!UUID_RE.test(id)) throw new Falha("Hub inválido.");
  if (!ids.length) return [];
  const { data, error } = await db().from("hubs").select("id").in("id", ids);
  if (error) throw error;
  if ((data || []).length !== ids.length) throw new Falha("Algum hub marcado não existe mais. Recarregue a tela.");
  return ids;
}
// Substitui a lista de hubs do usuário pela informada.
async function gravarHubs(uid: string, hubs: string[]) {
  const { data: atuais, error } = await db().from("usuarios_hubs").select("hub_id").eq("user_id", uid);
  if (error) throw error;
  const tem = new Set((atuais || []).map((r: any) => r.hub_id as string));
  const sair = [...tem].filter((h) => !hubs.includes(h));
  const entrar = hubs.filter((h) => !tem.has(h));
  if (sair.length) {
    const { error: e1 } = await db().from("usuarios_hubs").delete().eq("user_id", uid).in("hub_id", sair);
    if (e1) throw e1;
  }
  if (entrar.length) {
    const { error: e2 } = await db().from("usuarios_hubs").insert(entrar.map((h) => ({ user_id: uid, hub_id: h })));
    if (e2) throw e2;
  }
}

async function todosLogins() {
  const users: any[] = [];
  for (let page = 1; page < 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    users.push(...data.users);
    if (data.users.length < 1000) break;
  }
  return users;
}

async function acaoListar() {
  const [{ data: perfis, error }, logins, { data: uh, error: e2 }, { data: hubs, error: e3 }] = await Promise.all([
    db().from("usuarios_perfil")
      .select("user_id, nome, papel, modulos_visualizacao, modulos_operador, matricula, ativo, created_at, updated_at"),
    todosLogins(),
    db().from("usuarios_hubs").select("user_id, hub_id"),
    db().from("hubs").select("id, nome").order("nome"),
  ]);
  if (error) throw error;
  if (e2) throw e2;
  if (e3) throw e3;
  const hubsDe = new Map<string, string[]>();
  for (const r of uh || []) hubsDe.set(r.user_id, [...(hubsDe.get(r.user_id) || []), r.hub_id]);
  const porId = new Map(logins.map((u) => [u.id, u]));
  const vistos = new Set<string>();
  const lista = (perfis || []).map((p: any) => {
    const u = porId.get(p.user_id);
    vistos.add(p.user_id);
    return {
      ...p,
      hubs: hubsDe.get(p.user_id) || [],
      email: u?.email ?? null,
      ultimo_acesso: u?.last_sign_in_at ?? null,
      login_bloqueado: !!(u?.banned_until && new Date(u.banned_until) > new Date()),
      sem_login: !u,
    };
  });
  // logins que existem no Auth mas nunca ganharam perfil (ex.: criados à mão no painel do Supabase)
  for (const u of logins) {
    if (vistos.has(u.id)) continue;
    lista.push({
      user_id: u.id, nome: null, papel: null, modulos_visualizacao: [], modulos_operador: [], matricula: null, hubs: [],
      ativo: false, created_at: u.created_at, updated_at: null, email: u.email ?? null,
      ultimo_acesso: u.last_sign_in_at ?? null,
      login_bloqueado: !!(u.banned_until && new Date(u.banned_until) > new Date()), sem_perfil: true,
    });
  }
  lista.sort((a: any, b: any) => String(a.nome || a.email || "").localeCompare(String(b.nome || b.email || ""), "pt-BR"));
  return { usuarios: lista, modulos: MODULOS, hubs: hubs || [] };
}

async function acaoCriar(body: any) {
  const email = String(body.email || "").trim().toLowerCase();
  if (!EMAIL_RE.test(email)) throw new Falha("E-mail inválido.");
  const perfil = await camposPerfil(body, null);
  const hubs = await validarHubs(body.hubs);
  if (usaHub(perfil) && !hubs.length) throw new Falha("Marque pelo menos um hub (vale para Manutenções e Qualidade da Frota).");
  let senha = String(body.senha || "");
  const gerada = !senha;
  if (gerada) senha = gerarSenha();
  else if (senha.length < 8) throw new Falha("A senha precisa ter pelo menos 8 caracteres.");

  const { data, error } = await admin.auth.admin.createUser({
    email, password: senha, email_confirm: true, user_metadata: { nome: perfil.nome },
  });
  if (error || !data?.user) {
    const msg = String(error?.message || "");
    if (/already|registered|exists/i.test(msg)) throw new Falha("Já existe um login com esse e-mail.", 409);
    throw new Falha("Não foi possível criar o login: " + msg);
  }
  const uid = data.user.id;
  const { error: e2 } = await db().from("usuarios_perfil").insert({ user_id: uid, ativo: true, ...perfil });
  if (e2) {
    // não deixa login sem perfil para trás
    await admin.auth.admin.deleteUser(uid).catch(() => {});
    throw new Falha("Não foi possível gravar o perfil: " + e2.message);
  }
  if (usaHub(perfil)) {
    try { await gravarHubs(uid, hubs); }
    catch (e) {
      await admin.auth.admin.deleteUser(uid).catch(() => {}); // perfil e hubs saem junto (cascade)
      throw new Falha("Não foi possível gravar os hubs: " + (e as Error).message);
    }
  }
  return { ok: true, user_id: uid, email, senha_gerada: gerada ? senha : null };
}

async function acaoEditar(body: any, eu: string) {
  const uid = String(body.user_id || "");
  if (!UUID_RE.test(uid)) throw new Falha("Usuário inválido.");
  const perfil = await camposPerfil(body, uid);
  if (uid === eu && perfil.papel !== "admin") throw new Falha("Você não pode tirar o seu próprio papel de admin.");
  const hubs = await validarHubs(body.hubs);
  if (usaHub(perfil) && !hubs.length) throw new Falha("Marque pelo menos um hub (vale para Manutenções e Qualidade da Frota).");
  const { data: u, error: eu1 } = await admin.auth.admin.getUserById(uid);
  if (eu1 || !u?.user) throw new Falha("Login não encontrado.", 404);
  const { data: atual } = await db().from("usuarios_perfil").select("user_id").eq("user_id", uid).maybeSingle();
  const agora = new Date().toISOString();
  const { error } = atual
    ? await db().from("usuarios_perfil").update({ ...perfil, updated_at: agora }).eq("user_id", uid)
    // login sem perfil: cria o perfil já ativo e garante que o login não está bloqueado
    : await db().from("usuarios_perfil").insert({ user_id: uid, ativo: true, ...perfil });
  if (error) throw new Falha("Não foi possível salvar: " + error.message);
  if (!atual) await admin.auth.admin.updateUserById(uid, { ban_duration: "none" });
  // sem Manutenções/Checklist (ou admin) a lista não vale: fica como está, não é apagada
  if (usaHub(perfil)) await gravarHubs(uid, hubs);
  return { ok: true };
}

async function acaoAtivo(body: any, eu: string, ativo: boolean) {
  const uid = String(body.user_id || "");
  if (!UUID_RE.test(uid)) throw new Falha("Usuário inválido.");
  if (uid === eu && !ativo) throw new Falha("Você não pode desativar o seu próprio acesso.");
  // primeiro o perfil: é ele que corta as permissões na hora (RLS checa `ativo`)
  const { data, error } = await db().from("usuarios_perfil")
    .update({ ativo, updated_at: new Date().toISOString() }).eq("user_id", uid).select("user_id");
  if (error) throw new Falha("Não foi possível salvar: " + error.message);
  if (!data || !data.length) throw new Falha("Usuário sem perfil. Edite e salve o perfil primeiro.", 404);
  // depois o login: impede entrar de novo e renovar a sessão aberta
  const { error: e2 } = await admin.auth.admin.updateUserById(uid, { ban_duration: ativo ? "none" : BAN_DESATIVADO });
  if (e2) {
    return { ok: true, aviso: ativo
      ? "Perfil reativado, mas o login continua bloqueado (" + e2.message + "). Tente reativar de novo."
      : "Permissões cortadas, mas o login não foi bloqueado (" + e2.message + "). Tente desativar de novo." };
  }
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return withCors(new Response(null, { status: 204 }));
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const eu = await exigirAdmin(req);
    const body = await req.json().catch(() => ({}));
    switch (body.acao) {
      case "listar": return json(await acaoListar());
      case "criar": return json(await acaoCriar(body));
      case "editar": return json(await acaoEditar(body, eu));
      case "desativar": return json(await acaoAtivo(body, eu, false));
      case "ativar": return json(await acaoAtivo(body, eu, true));
      default: return json({ error: "Ação desconhecida." }, 400);
    }
  } catch (e) {
    const status = e instanceof Falha ? e.status : 500;
    if (!(e instanceof Falha)) console.error("usuarios:", e);
    return json({ error: (e as Error).message || String(e) }, status);
  }
});
