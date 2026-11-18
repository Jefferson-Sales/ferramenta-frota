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

// ---------- Pipe "90. Pagamento a fornecedor" (pedido do Jefferson, 18/11/2026) ----------
// IDs mapeados pelo Jefferson no navegador (não são segredo). Leitura só para conferir o acesso do token
// e achar os field_id da API e os registros das bases conectadas.
const PIPE_PAGAMENTO = "301583172";
const BASES_PAGAMENTO: Record<string, { id: string; registros: boolean }> = {
  empresa_tomadora: { id: "a104bd7e-f25b-4537-9bac-c7a90df9b0fc", registros: true },
  filial: { id: "d5a85ffc-23ab-4221-b4b0-4b39939032e3", registros: true },
  centro_custo: { id: "191af2fc-108f-4dff-8589-03fb0c92601a", registros: true },
  fornecedor: { id: "b1f552c2-39e6-4d7b-bc6f-99661f9ff0d1", registros: false },   // pode ter CPF: só estrutura e contagem
};
// Mapa do formulário inicial (fase 310493754, organização 353414), na ordem da tela do Pipefy. `id` = field_id da API:
// fica "TODO" até o modo descobrir_pagamento responder (hoje o Pipefy nega acesso ao pipe para o dono do token).
// `de` = de onde vem o valor (triagem financeira aprovada + cadastro do fornecedor); a mesma ordem e regras estão em
// Regras.resumoPipefyPagamento (usada no plano B "Copiar resumo para Pipefy").
// Para virar a chave: rodar descobrir_pagamento, preencher os ids (e o id do registro de cada base conectada),
// trocar o envio do plano B por createCard + anexos (createPresignedUrl, como desenhado na P1) e gravar o card.
export const MAPA_PAGAMENTO = [
  { n: 1, campo: "Descrição do serviço contratado ou mercadoria adquirida", tipo: "short_text", id: "TODO", de: "fornecedores.servico_descricao | assunto do e-mail" },
  { n: 2, campo: "Empresa tomadora (Beep)", tipo: "connector", base: BASES_PAGAMENTO.empresa_tomadora.id, id: "TODO", de: "registro fixo da Beep" },
  { n: 3, campo: "Filial", tipo: "connector", base: BASES_PAGAMENTO.filial.id, id: "TODO", de: "hub mais usado nas notas do fornecedor (de-para hub → filial a montar)" },
  { n: 4, campo: "Centro de custo", tipo: "connector", base: BASES_PAGAMENTO.centro_custo.id, id: "TODO", de: "a definir com o Financeiro (condicional)" },
  { n: 5, campo: "CNPJ ou CPF do Fornecedor", tipo: "connector", base: BASES_PAGAMENTO.fornecedor.id, id: "TODO", de: "fornecedores.cnpj → registro da base" },
  { n: 6, campo: "Anexar nota fiscal ou fatura ou recibo", tipo: "attachment", id: "TODO", de: "notas-triagem/{id}/nf.pdf" },
  { n: 7, campo: "Número do documento anexado", tipo: "short_text", id: "TODO", de: "numero_nota_lido" },
  { n: 8, campo: "Data de emissão do documento", tipo: "date", id: "TODO", de: "a ler do XML/PDF" },
  { n: 9, campo: "Data de vencimento", tipo: "date", id: "TODO", de: "data_vencimento" },
  { n: 10, campo: "Data de pagamento", tipo: "date", id: "TODO", de: "Regras.dataPagamentoPipefy (vencimento, ou hoje + 10 dias corridos)" },
  { n: 11, campo: "Ano de competência", tipo: "select", id: "TODO", de: "ano da competência (2025/2026/2027)" },
  { n: 12, campo: "Mês de competência", tipo: "select", id: "TODO", de: "mês da competência (1–12)" },
  { n: 13, campo: "Forma de pagamento", tipo: "radio_vertical", id: "TODO", de: "fornecedores.forma_pagamento (Boleto, Transferência, Débito Automático, Guia, PIX)" },
  { n: 13.1, campo: "Anexar boleto (se Boleto)", tipo: "attachment", id: "TODO", de: "notas-triagem/{id}/boleto.pdf" },
  { n: 13.2, campo: "Solicitei alteração cadastral de dados bancários (se Transferência/PIX)", tipo: "radio_vertical", id: "TODO", de: "Não (padrão)" },
  { n: 14, campo: "Valor a pagar", tipo: "currency", id: "TODO", de: "valor_lido" },
  { n: 15, campo: "Observações", tipo: "long_text", id: "TODO", de: "remetente e data de recebimento" },
];
const Q_PIPE_PAG = `query($id: ID!) {
  pipe(id: $id) { id name organizationId
    start_form_fields { id label type required options description } }
}`;
const Q_CONECTORES = `query($id: ID!) {
  pipe(id: $id) { start_form_fields { id label type connectedRepo { ... on Table { id name } ... on Pipe { id name } } } }
}`;
const Q_TABELA = `query($id: ID!) { table(id: $id) { id name table_records_count table_fields { id label type } } }`;
const Q_TABELA_REG = `query($id: ID!) { table(id: $id) { table_records(first: 100) { edges { node { id title } } } } }`;
async function descobrirPagamento() {
  const r: Record<string, unknown> = {};
  try { await pipefy(Q_TOKEN, {}); r.token = "ok"; } catch (e) { r.token = (e as Error).message; }
  try { r.pipe = (await pipefy(Q_PIPE_PAG, { id: PIPE_PAGAMENTO })).pipe; } catch (e) { r.pipe_erro = (e as Error).message; }
  try { r.conectores = (await pipefy(Q_CONECTORES, { id: PIPE_PAGAMENTO })).pipe?.start_form_fields?.filter((f: any) => f.connectedRepo); }
  catch (e) { r.conectores_erro = (e as Error).message; }
  const bases: Record<string, unknown> = {};
  for (const [nome, b] of Object.entries(BASES_PAGAMENTO)) {
    const x: Record<string, unknown> = {};
    try { x.tabela = (await pipefy(Q_TABELA, { id: b.id })).table; } catch (e) { x.erro = (e as Error).message; }
    if (b.registros && !x.erro) {
      try { x.registros = (await pipefy(Q_TABELA_REG, { id: b.id })).table?.table_records?.edges?.map((ed: any) => ed.node); }
      catch (e) { x.registros_erro = (e as Error).message; }
    }
    bases[nome] = x;
  }
  r.bases = bases;
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
      if (modo === "descobrir_pagamento") return json(await descobrirPagamento());
      if (modo !== "descobrir") throw new Falha("Com a chave interna, só os modos de leitura (descobrir).", 403);
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
