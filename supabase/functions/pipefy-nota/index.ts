// Edge Function `pipefy-nota` — envia uma nota fiscal já gravada no banco para o pipe
// "Contas a Pagar" do Pipefy (GraphQL) e grava o número do card devolvido como Pipe da nota.
//
// ESTADO: ESQUELETO (P1). Publicado com o envio TRAVADO (CAMPOS vazio). Falta: IDs reais dos campos (modo "descobrir"),
// colunas de controle do envio (migration P2) e anexos (P3).
//
// Ordem segura (para nunca criar card em dobro):
//   1) a tela salva a nota no banco como "pendente_envio" (já é assim hoje);
//   2) a tela chama esta função com o id da nota;
//   3) a função reserva o envio (P2), cria o card, e chama nf_registrar_envio com o id do card.
//   Se o passo 3 falhar depois de criar o card, a reserva guarda o id do card e o reenvio só
//   completa o banco, sem criar outro card.
//
// Segurança: verify_jwt = false na plataforma (preflight CORS); o JWT é conferido aqui.
// O banco é lido COM O LOGIN DE QUEM CHAMOU (o RLS vale: só admin/operador do Financeiro
// envia, e dados bancários só aparecem para quem pode vê-los). O token do Pipefy fica só
// no segredo PIPEFY_TOKEN da Edge Function — nunca no navegador, no código ou no chat.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const servico = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const PIPEFY_TOKEN = Deno.env.get("PIPEFY_TOKEN") || "";
const PIPEFY_PIPE_ID = Deno.env.get("PIPEFY_PIPE_CONTAS_PAGAR") || "92306294"; // pipe Contas a Pagar (não é segredo)
const PIPEFY_URL = "https://api.pipefy.com/graphql";

// Campo do nosso banco → id do campo no formulário inicial do pipe.
// Os ids NÃO são segredo; são preenchidos depois de rodar o modo "descobrir".
// `tipo` diz como o valor vai formatado (data, moeda, opção de lista, texto).
const CAMPOS: Record<string, { id: string; tipo: "texto" | "data" | "moeda" | "opcao" | "conector" }> = {
  // fornecedor:        { id: "TODO", tipo: "texto" },   // ou "conector" se o pipe usar uma tabela de fornecedores
  // cnpj:              { id: "TODO", tipo: "texto" },
  // numero_nota:       { id: "TODO", tipo: "texto" },
  // valor:             { id: "TODO", tipo: "moeda" },
  // data_emissao:      { id: "TODO", tipo: "data" },
  // data_vencimento:   { id: "TODO", tipo: "data" },
  // forma_pagamento:   { id: "TODO", tipo: "opcao" },   // texto tem que ser IGUAL à opção do Pipefy
  // centro_custo_hub:  { id: "TODO", tipo: "opcao" },
  // categoria:         { id: "TODO", tipo: "opcao" },
  // competencia:       { id: "TODO", tipo: "texto" },
  // descricao:         { id: "TODO", tipo: "texto" },
  // banco / agencia / conta: só se o formulário pedir (transferência/PIX)
};
// De/para das nossas opções para o texto exato das opções do Pipefy (preencher após "descobrir").
const OPCOES: Record<string, Record<string, string>> = {
  // forma_pagamento: { BOLETO: "Boleto", "TRANSFERÊNCIA": "Transferência bancária", PIX: "Pix" },
};

function withCors(resp: Response) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Headers", "authorization, content-type, apikey, x-client-info, x-automation-key");
  resp.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return resp;
}
function json(body: unknown, status = 200) {
  return withCors(new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } }));
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }

// ---------- Pipefy ----------
async function pipefy(query: string, variables: Record<string, unknown>) {
  if (!PIPEFY_TOKEN) throw new Falha("Integração sem token configurado.", 500);
  const r = await fetch(PIPEFY_URL, {
    method: "POST",
    headers: { "Authorization": "Bearer " + PIPEFY_TOKEN, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || body.errors?.length) {
    // nunca devolver o token nem o cabeçalho; só a mensagem do Pipefy
    const msg = body.errors?.map((e: any) => e.message).join("; ") || ("HTTP " + r.status);
    throw new Falha("Pipefy recusou: " + msg, 502);
  }
  return body.data;
}

// Lista os campos do formulário inicial e de cada fase (para preencher CAMPOS/OPCOES) e a
// organização (necessária para subir anexo). Só leitura. Não pede membros (nomes/e-mails).
const Q_TOKEN = `query { me { id } }`;
const Q_PIPE = `query($id: ID!) {
  pipe(id: $id) {
    id name
    start_form_fields { id label type required options description }
    phases { id name fields { id label type required options } }
  }
}`;
const Q_ORG = `query($id: ID!) { pipe(id: $id) { organizationId } }`;

// Faz as três leituras separadas, para dizer qual parte o Pipefy recusa.
async function descobrir() {
  const r: Record<string, unknown> = {};
  try { await pipefy(Q_TOKEN, {}); r.token = "ok"; } catch (e) { r.token = (e as Error).message; }
  try { r.pipe = (await pipefy(Q_PIPE, { id: PIPEFY_PIPE_ID })).pipe; } catch (e) { r.pipe_erro = (e as Error).message; }
  try { r.organizacao = (await pipefy(Q_ORG, { id: PIPEFY_PIPE_ID })).pipe?.organizationId; } catch (e) { r.organizacao_erro = (e as Error).message; }
  return r;
}

// Criação do card: sempre com variáveis (nunca montar a mutation colando texto da nota).
const M_CRIAR_CARD = `mutation($input: CreateCardInput!) {
  createCard(input: $input) { card { id title url } }
}`;

// ---------- montagem (pura; vira teste quando os ids existirem) ----------
function formatar(tipo: string, chave: string, v: unknown): unknown {
  if (v == null || v === "") return null;
  if (tipo === "data") return String(v).slice(0, 10);                    // AAAA-MM-DD
  if (tipo === "moeda") return Number(v).toFixed(2);                      // "3750.00"
  if (tipo === "opcao") {
    const t = OPCOES[chave]?.[String(v)] ?? String(v);
    return t;
  }
  if (tipo === "conector") return [String(v)];                            // ids de registro/card
  return String(v);
}

export function montarCard(nota: any, forn: any, banc: any | null) {
  const valores: Record<string, unknown> = {
    fornecedor: forn?.razao_social || forn?.nome,
    cnpj: forn?.cnpj,
    numero_nota: nota.numero_nota,
    valor: nota.valor,
    data_emissao: nota.data_emissao,
    data_vencimento: nota.data_vencimento,
    forma_pagamento: nota.forma_pagamento,
    centro_custo_hub: nota.hubs?.nome,
    categoria: nota.categorias_custo?.nome,
    competencia: String(nota.mes_referencia || "").slice(5, 7) + "/" + String(nota.mes_referencia || "").slice(0, 4),
    descricao: nota.descricao,
    banco: banc?.banco, agencia: banc?.agencia, conta: banc?.conta,
  };
  const fields_attributes = Object.entries(CAMPOS)
    .map(([chave, c]) => ({ field_id: c.id, field_value: formatar(c.tipo, chave, valores[chave]) }))
    .filter((f) => f.field_value != null);
  return {
    pipe_id: PIPEFY_PIPE_ID,
    title: `${valores.fornecedor} — NF ${nota.numero_nota || "s/n"}`,
    fields_attributes,
  };
}

// ---------- servidor ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return withCors(new Response("ok"));
  try {
    const body = await req.json().catch(() => ({}));
    const modo = String(body.modo || "");

    // Chave interna (Vault automation_secret_questar, lida dentro do SQL): SÓ o modo "descobrir".
    const chave = req.headers.get("x-automation-key") || "";
    if (chave) {
      const { data: ok } = await servico.schema("frota").rpc("verificar_automation_key", { chave });
      if (ok !== true) throw new Falha("Chave inválida.", 401);
      if (modo !== "descobrir") throw new Falha("Com a chave interna, só o modo descobrir.", 403);
      return json(await descobrir());
    }

    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) throw new Falha("Faça login.", 401);
    // cliente com o login de quem chamou: todo acesso ao banco passa pelo RLS
    const sb = createClient(SUPABASE_URL, ANON_KEY, {
      auth: { persistSession: false }, global: { headers: { Authorization: "Bearer " + jwt } },
    });
    const db = sb.schema("frota");
    const { data: u } = await sb.auth.getUser(jwt);
    if (!u?.user) throw new Falha("Sessão inválida ou expirada.", 401);
    const { data: papel } = await db.rpc("meu_papel");
    const { data: opera } = await db.rpc("tenho_modulo", { modulo: "financeiro" });
    if (papel !== "admin" && !opera) throw new Falha("Só admin ou quem opera o Financeiro envia ao Pipefy.", 403);

    if (modo === "descobrir") {                       // só admin; só leitura no Pipefy
      if (papel !== "admin") throw new Falha("Só admin.", 403);
      return json(await descobrir());
    }

    if (modo === "previa" || modo === "enviar") {
      const id = String(body.nota_id || "");
      const { data: nota, error } = await db.from("notas_fiscais")
        .select("id, numero_nota, valor, data_emissao, data_vencimento, mes_referencia, forma_pagamento, descricao, etapa, pipefy_card_id, fornecedor_id, hubs(nome), categorias_custo(nome)")
        .eq("id", id).maybeSingle();
      if (error) throw error;
      if (!nota) throw new Falha("Nota não encontrada.", 404);
      if (nota.etapa !== "pendente_envio" && nota.etapa !== "recusado") throw new Falha("Essa nota já foi enviada.");
      const { data: forn } = await db.from("fornecedores").select("*").eq("id", nota.fornecedor_id).maybeSingle();
      const { data: banc } = await db.from("fornecedores_dados_bancarios").select("banco, agencia, conta")
        .eq("fornecedor_id", nota.fornecedor_id).maybeSingle();       // vazio se a pessoa não pode ver
      const input = montarCard(nota, forn, banc);

      if (modo === "previa") return json({ input });    // mostra o que IRIA, não chama o Pipefy

      // Trava do esqueleto: sem mapeamento conferido (e sem a reserva da P2), não cria card.
      if (Object.keys(CAMPOS).length === 0) throw new Falha("Envio ao Pipefy ainda não liberado (mapeamento em construção).", 409);

      // TODO P2: reservar o envio (frota.nf_reservar_envio_pipefy(id)) — impede card em dobro
      //          com dois cliques ou duas abas; se já houver card criado sem Pipe gravado, pula a criação.
      const data = await pipefy(M_CRIAR_CARD, { input });
      const card = data.createCard.card;
      const hoje = new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10);   // dia de Brasília
      const { error: e2 } = await db.rpc("nf_registrar_envio", { p_id: id, p_pipe: String(card.id), p_data: hoje });
      if (e2) throw new Falha("Card " + card.id + " criado no Pipefy, mas a nota não foi atualizada: " + e2.message, 500);
      return json({ ok: true, pipe: card.id, url: card.url });
    }
    throw new Falha("Modo desconhecido.");
  } catch (e) {
    const st = e instanceof Falha ? e.status : 500;
    return json({ erro: (e as Error).message }, st);
  }
});
