// Edge Function `inbound-triagem-nfs` — webhook que recebe os e-mails enviados para frota@ e coloca cada um na fila de
// triagem certa: multas, orçamentos de oficina ou notas/boletos (T1 13/11/2026; T2 16/11/2026; M1 17/11; O1 18/11).
//
// Fluxo: fornecedor → frota@beepsaude.com.br → cópia para o endereço de inbound do provedor (recomendado: Postmark)
// → POST aqui → PDFs num bucket PRIVADO → linha pendente na fila. Ordem das rotas:
//   1. multa  (Regras.ehEmailDeMulta)      → frota.multas_triagem               (bucket multas-triagem, {id}/notificacao.pdf)
//   2. orçamento (Regras.ehEmailDeOrcamento: orçamento/cotação/proposta/estimativa de prazo, e NÃO NF/DANFE/boleto)
//                                          → frota.manutencao_orcamentos_triagem (bucket manutencao-orcamentos, {id}/orcamento.pdf)
//   3. o resto                             → frota.financeiro_notas_triagem      (bucket notas-triagem, {id}/nf.pdf e boleto.pdf)
//
// Regras (pedido do Jefferson, 16/11/2026):
//  - guarda SÓ os PDFs: o 1º com cara de boleto vira {id}/boleto.pdf, o 1º outro vira {id}/nf.pdf, os demais
//    {id}/outros/N.pdf. E-mail sem PDF é ignorado (responde 200 para o provedor não reenviar).
//  - fornecedor: o banco procura (gatilho tg_triagem_notas → triagem_achar_fornecedor) pelo CNPJ lido do XML da
//    NF-e/NFS-e ou do assunto e, sem CNPJ, pelo e-mail do remetente = contato_email de um fornecedor ativo.
//    O XML e o texto dos PDFs são lidos só na memória (unpdf); não são guardados.
//  - vencimento fica em branco: é conferido na tela (ou por OCR, depois).
//
// Segurança:
//  - verify_jwt = false (quem chama é o provedor de e-mail). Toda chamada do provedor precisa da chave do Vault
//    `inbound_triagem_chave` (conferida no banco por frota.verificar_inbound_triagem, só service_role), enviada
//    de um destes jeitos: cabeçalho x-inbound-key, ?chave= na URL, ou senha do Basic Auth (https://x:CHAVE@…,
//    formato do Postmark). Sem chave certa: 401.
//  - grava com service_role (as filas não aceitam INSERT de ninguém logado); guarda o CAMINHO do arquivo, nunca link.
//  - não guarda o corpo do e-mail nem o escreve no log; só remetente, assunto, id da mensagem e os PDFs.
//
// "Mover para…" (O1, 18/11/2026): ?acao=mover, corpo { de, id, para, motivo } com de/para = financeiro | orcamentos |
// multas. Chamada pela TELA com o login da pessoa (Authorization: Bearer <token>): frota.triagem_mover_autorizacao,
// rodando com esse login, confere que o item está pendente e que a pessoa opera a fila de origem. Também aceita a
// chave do Vault em x-inbound-key (automação/migração; registra "Automação"). O item entra pendente na fila de
// destino com os mesmos PDFs (lidos de novo), sai da origem (linha e arquivos) e fica registrado em
// frota.triagem_movimentacoes (imutável). Com ?teste=1 só mostra o que faria.
//
// Resposta à oficina (O2, 18/11/2026): ?acao=responder_orcamento, corpo { id }, com o login de quem decidiu
// (frota.orcamento_resposta_preparar confere acesso e que o orçamento já foi decidido e ainda não respondido).
// Envia pelo Postmark se houver POSTMARK_SERVER_TOKEN + POSTMARK_FROM; senão devolve os dados para a tela abrir
// o e-mail da pessoa (mailto). Canal, hora e erro do envio ficam no orçamento (só o sistema grava).
//
// Formatos aceitos:
//  - JSON do Postmark Inbound (FromFull, Subject, Headers, MessageID, Attachments[{Name, ContentType, Content}]);
//  - multipart/form-data (SendGrid Inbound Parse, Mailgun Routes): from/sender, subject, headers ou Message-Id, arquivos;
//  - JSON normalizado: { remetente, assunto, message_id, anexos: [{ nome, tipo, base64 }] }.
// Modo teste (cabeçalho x-inbound-teste: 1 ou ?teste=1): lê tudo e responde o que faria, sem gravar nada.
// Idempotente: o mesmo message_id não cria segunda linha na mesma fila.
//
// IMPORTANTE: regras-multa.js é GERADO do /regras.js da raiz (fonte única, com testes). Antes de publicar:
//   node ferramentas/gerar-regras-multa.js
import { createClient } from "npm:@supabase/supabase-js@2";
import { extractText, getDocumentProxy } from "npm:unpdf@0.12.1";
import "./regras-multa.js";
// deno-lint-ignore no-explicit-any
const R = (globalThis as any).RegrasMulta;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const BUCKET = "notas-triagem";
const BUCKET_MULTAS = "multas-triagem";
const BUCKET_ORC = "manutencao-orcamentos";
const MAX_BYTES = 10 * 1024 * 1024;   // limite dos buckets
const MAX_ANEXOS = 15;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }

type Anexo = { nome: string; tipo: string; bytes: Uint8Array };
type Email = { remetente: string | null; assunto: string | null; messageId: string | null; anexos: Anexo[]; formato: string };
type Origem = { messageId: string | null; remetente: string | null; assunto: string | null; dataRecebimento?: string | null; origem: string };
type Subido = { bucket: string; caminho: string };

// ---------- chave ----------
function chaveRecebida(req: Request) {
  const h = req.headers.get("x-inbound-key");
  if (h) return h;
  const q = new URL(req.url).searchParams.get("chave");
  if (q) return q;
  const auth = req.headers.get("authorization") || "";
  if (/^basic /i.test(auth)) {
    try { const dec = atob(auth.slice(6).trim()); return dec.slice(dec.indexOf(":") + 1); } catch { return ""; }
  }
  return "";
}
async function chaveValida(chave: string) {
  if (!chave || chave.length < 32) return false;
  const { data, error } = await db().rpc("verificar_inbound_triagem", { chave });
  if (error) throw new Falha("Não foi possível conferir a chave.", 500);
  return data === true;
}

// ---------- leitura do e-mail ----------
function b64(s: string) { return Uint8Array.from(atob(String(s || "").replace(/\s/g, "")), (c) => c.charCodeAt(0)); }
// "Fulano <nf@empresa.com>" → "nf@empresa.com"
function limparRemetente(s: string) {
  const m = String(s || "").match(/[^\s<>"]+@[^\s<>"]+/);
  return m ? m[0].toLowerCase().slice(0, 200) : null;
}
const corta = (s: unknown, n = 300) => String(s ?? "").trim().slice(0, n) || null;

async function lerEmail(req: Request): Promise<Email> {
  const ct = req.headers.get("content-type") || "";
  if (ct.includes("multipart/form-data")) {
    const form = await req.formData();
    const anexos: Anexo[] = [];
    for (const [, v] of form.entries()) {
      if (v instanceof File && anexos.length < MAX_ANEXOS) anexos.push({ nome: v.name || "anexo", tipo: v.type || "", bytes: new Uint8Array(await v.arrayBuffer()) });
    }
    const cab = String(form.get("headers") || "");
    const mid = String(form.get("Message-Id") || form.get("message-id") || "") || (cab.match(/^message-id:\s*(.+)$/im)?.[1] ?? "");
    return { remetente: limparRemetente(String(form.get("from") || form.get("sender") || "")), assunto: corta(form.get("subject")),
      messageId: corta(mid), anexos, formato: "multipart" };
  }
  const b = await req.json().catch(() => { throw new Falha("Corpo inválido."); });
  if (b && (b.FromFull || b.Attachments || b.MessageID)) {           // Postmark Inbound
    const cab = Array.isArray(b.Headers) ? b.Headers : [];
    const mid = cab.find((h: any) => /^message-id$/i.test(String(h?.Name)))?.Value || (b.MessageID ? "postmark:" + b.MessageID : "");
    return {
      remetente: limparRemetente(b.FromFull?.Email || b.From || ""), assunto: corta(b.Subject), messageId: corta(mid), formato: "postmark",
      anexos: (Array.isArray(b.Attachments) ? b.Attachments : []).slice(0, MAX_ANEXOS)
        .map((a: any) => ({ nome: String(a.Name || "anexo"), tipo: String(a.ContentType || ""), bytes: b64(a.Content) })),
    };
  }
  return {
    remetente: limparRemetente(b.remetente), assunto: corta(b.assunto), messageId: corta(b.message_id), formato: "normalizado",
    anexos: (Array.isArray(b.anexos) ? b.anexos : []).slice(0, MAX_ANEXOS)
      .map((a: any) => ({ nome: String(a.nome || "anexo"), tipo: String(a.tipo || ""), bytes: b64(a.base64) })),
  };
}

// ---------- anexos: só PDF ----------
function ehPdf(a: Anexo) {
  const assinatura = a.bytes.length > 4 && a.bytes[0] === 0x25 && a.bytes[1] === 0x50 && a.bytes[2] === 0x44 && a.bytes[3] === 0x46; // %PDF
  return assinatura || /pdf/i.test(a.tipo) || /\.pdf$/i.test(a.nome);
}
function ehXml(a: Anexo) { return /xml/i.test(a.tipo) || /\.xml$/i.test(a.nome); }
function classificar(anexos: Anexo[]) {
  const pdfs = anexos.filter((a) => ehPdf(a) && a.bytes.length > 0 && a.bytes.length <= MAX_BYTES);
  const boleto = pdfs.find((a) => /boleto|\bbol\b|fatura|cobran|pagamento/i.test(a.nome)) || null;
  const nf = pdfs.find((a) => a !== boleto && /nf|nota|danfe|nfs/i.test(a.nome)) || pdfs.find((a) => a !== boleto) || null;
  const outros = pdfs.filter((a) => a !== boleto && a !== nf);
  const grandes = anexos.filter((a) => ehPdf(a) && a.bytes.length > MAX_BYTES).length;
  return { nf, boleto, outros, ignorados: anexos.length - pdfs.length, grandes, xml: anexos.find((a) => ehXml(a) && a.bytes.length <= MAX_BYTES) || null };
}

// ---------- dados do XML (só memória) e do assunto ----------
function lerDados(xml: Anexo | null, assunto: string | null) {
  const d: { cnpj: string | null; valor: number | null; numero: string | null } = { cnpj: null, valor: null, numero: null };
  if (xml) {
    const t = new TextDecoder().decode(xml.bytes);
    const tag = (re: RegExp) => t.match(re)?.[1]?.trim() || null;
    d.cnpj = tag(/<emit>[\s\S]*?<CNPJ>(\d{14})<\/CNPJ>/i) || tag(/<(?:PrestadorServico|Prestador)[\s\S]*?<Cnpj>(\d{14})<\/Cnpj>/i) || tag(/<CNPJ>(\d{14})<\/CNPJ>/i);
    const v = tag(/<vNF>([\d.]+)<\/vNF>/i) || tag(/<ValorLiquidoNfse>([\d.]+)<\//i) || tag(/<ValorServicos>([\d.]+)<\//i);
    d.valor = v ? Number(v) : null;
    d.numero = tag(/<nNF>(\d+)<\/nNF>/i) || tag(/<Numero>(\d+)<\/Numero>/i);
  }
  if (!d.cnpj && assunto) {
    const m = assunto.match(/\b(\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2})\b/);
    if (m) d.cnpj = m[1].replace(/\D/g, "");
  }
  if (d.valor != null && !(d.valor > 0)) d.valor = null;
  return d;
}

// ---------- texto dos PDFs (só memória; escaneado = sem texto) ----------
// um texto por PDF (até 8; os demais ficam vazios)
async function textosPorPdf(pdfs: Anexo[]) {
  const partes: string[] = [];
  for (let i = 0; i < pdfs.length; i++) {
    let t = "";
    if (i < 8) {
      try {
        const doc = await getDocumentProxy(new Uint8Array(pdfs[i].bytes));   // cópia: a leitura pode consumir o buffer
        const { text } = await extractText(doc, { mergePages: true });
        t = String(text || "").slice(0, 20000);
      } catch { /* PDF sem texto ou protegido */ }
    }
    partes.push(t);
  }
  return partes;
}
const juntar = (textos: string[]) => textos.slice(0, 3).join("\n");

async function subirEm(subidos: Subido[], bucket: string, caminho: string, a: Anexo) {
  const { error } = await admin.storage.from(bucket).upload(caminho, a.bytes, { contentType: "application/pdf", upsert: false });
  if (error) throw new Falha("Não foi possível guardar o anexo: " + error.message, 500);
  subidos.push({ bucket, caminho }); return caminho;
}
async function jaExiste(tabela: string, messageId: string | null) {
  if (!messageId) return null;
  const { data } = await db().from(tabela).select("id").eq("message_id", messageId).maybeSingle();
  return data?.id ?? null;
}

// ---------- fila 1: multas ----------
async function gravarMulta(e: Origem, pdfs: Anexo[], texto: string, motivo: string, teste: boolean, subidos: Subido[]) {
  const campos = R.lerNotificacaoMulta(texto, e.assunto);
  if (teste) return { ok: true, teste: true, fila: "multas", motivo, campos, pdfs: pdfs.map((a) => a.nome), texto_lido: texto.length > 0,
    datas_candidatas: R.datasDaNotificacao(texto).map((c: { iso: string; hora: string | null; antes: string; bloqueada: boolean; infracao: boolean }) =>
      ({ data: c.iso, hora: c.hora, trecho_antes: c.antes, ignorada: c.bloqueada, perto_de_infracao: c.infracao })) };
  const ja = await jaExiste("multas_triagem", e.messageId);
  if (ja) return { ok: true, fila: "multas", duplicado: true, id: ja };
  const id = crypto.randomUUID();
  const caminho = pdfs[0] ? await subirEm(subidos, BUCKET_MULTAS, `${id}/notificacao.pdf`, pdfs[0]) : null;
  for (let i = 1; i < pdfs.length; i++) await subirEm(subidos, BUCKET_MULTAS, `${id}/outros/${i}.pdf`, pdfs[i]);
  const linha: Record<string, unknown> = {
    id, message_id: e.messageId, origem: e.origem, remetente: e.remetente, assunto: e.assunto, motivo_deteccao: motivo,
    caminho_pdf: caminho, outros_anexos: Math.max(pdfs.length - 1, 0), placa_lida: campos.placa, data_infracao: campos.data_infracao,
    ait: campos.ait, orgao: campos.orgao, codigo_infracao: campos.codigo, valor_lido: campos.valor,
  };
  if (e.dataRecebimento) linha.data_recebimento = e.dataRecebimento;
  const { data: gravada, error } = await db().from("multas_triagem").insert(linha).select("veiculo_id, sugestao_checklist_id").single();
  if (error) throw new Falha("Não foi possível gravar a multa: " + error.message, 500);
  return { ok: true, fila: "multas", id, placa_lida: !!campos.placa, veiculo: !!gravada?.veiculo_id, condutor_sugerido: !!gravada?.sugestao_checklist_id, pdfs: pdfs.length };
}

// ---------- fila 2: orçamentos de oficina (Manutenções) ----------
// PDFs de placas diferentes no mesmo e-mail viram itens separados (Regras.separarOrcamentos); o 2º em diante
// recebe message_id "<id>#2", "#3"… para o reenvio do mesmo e-mail continuar sem duplicar.
async function gravarOrcamento(e: Origem, pdfs: Anexo[], textos: string[], motivo: string, teste: boolean, subidos: Subido[]) {
  const grupos: { pdfs: number[]; campos: { placa: string | null; cnpjs: string[]; valor: number | null; descricao: string | null } }[] =
    R.separarOrcamentos(textos, e.assunto);
  if (teste) return { ok: true, teste: true, fila: "orcamentos", motivo, pdfs: pdfs.map((a) => a.nome), itens: grupos.map((g) => ({
    pdfs: g.pdfs.map((i) => pdfs[i]?.nome), campos: g.campos, texto_lido: g.pdfs.some((i) => (textos[i] || "").length > 0) })) };
  const ja = await jaExiste("manutencao_orcamentos_triagem", e.messageId);
  if (ja) return { ok: true, fila: "orcamentos", duplicado: true, id: ja };
  const ids: string[] = [], itens: unknown[] = [];
  for (let g = 0; g < grupos.length; g++) {
    const { campos } = grupos[g], meus = grupos[g].pdfs.map((i) => pdfs[i]).filter(Boolean);
    const id = crypto.randomUUID();
    const caminho = meus[0] ? await subirEm(subidos, BUCKET_ORC, `${id}/orcamento.pdf`, meus[0]) : null;
    for (let i = 1; i < meus.length; i++) await subirEm(subidos, BUCKET_ORC, `${id}/outros/${i}.pdf`, meus[i]);
    const linha: Record<string, unknown> = {
      id, message_id: g === 0 || !e.messageId ? e.messageId : `${e.messageId}#${g + 1}`, origem: e.origem === "email" ? "email" : "movida",
      remetente: e.remetente, assunto: e.assunto,
      motivo_deteccao: motivo + (grupos.length > 1 ? ` (orçamento ${g + 1} de ${grupos.length} do mesmo e-mail)` : ""),
      caminho_pdf: caminho, outros_anexos: Math.max(meus.length - 1, 0),
      placa_lida: campos.placa, cnpjs_lidos: campos.cnpjs, valor_lido: campos.valor, descricao_lida: campos.descricao,
    };
    if (e.dataRecebimento) linha.data_recebimento = e.dataRecebimento;
    const { data: gravada, error } = await db().from("manutencao_orcamentos_triagem").insert(linha)
      .select("veiculo_id, os_sugerida_id, oficina_id").single();
    if (error) {
      if (ids.length) await db().from("manutencao_orcamentos_triagem").delete().in("id", ids);
      throw new Falha("Não foi possível gravar o orçamento: " + error.message, 500);
    }
    ids.push(id);
    itens.push({ id, placa: campos.placa, veiculo: !!gravada?.veiculo_id, os_sugerida: !!gravada?.os_sugerida_id, oficina: !!gravada?.oficina_id,
      valor: campos.valor, pdfs: meus.length });
  }
  return { ok: true, fila: "orcamentos", id: ids[0], ids, itens };
}

// ---------- fila 3: notas e boletos (Financeiro) ----------
async function gravarFinanceiro(e: Origem, anexos: Anexo[], xml: Anexo | null, teste: boolean, subidos: Subido[], formato = "") {
  const c = classificar(anexos);
  const dados = lerDados(xml, e.assunto);
  if (teste) {
    const { data: ach } = await db().rpc("triagem_achar_fornecedor", { p_cnpj: dados.cnpj, p_email: e.remetente });
    const f = Array.isArray(ach) ? ach[0] : null;
    return { ok: true, teste: true, fila: "financeiro", formato, remetente: e.remetente, assunto: e.assunto, message_id: e.messageId,
      nf: c.nf?.nome ?? null, boleto: c.boleto?.nome ?? null, outros_pdfs: c.outros.map((a) => a.nome),
      ignorados_nao_pdf: c.ignorados, pdfs_grandes_demais: c.grandes, lidos: dados,
      fornecedor: f ? { id: f.fornecedor_id, achado_por: f.achado_por } : null };
  }
  const ja = await jaExiste("financeiro_notas_triagem", e.messageId);
  if (ja) return { ok: true, fila: "financeiro", duplicado: true, id: ja };
  if (!c.nf && !c.boleto) return { ok: true, fila: "financeiro", ignorado: "e-mail sem anexo PDF", pdfs_grandes_demais: c.grandes };
  const id = crypto.randomUUID();
  const subir = (caminho: string, a: Anexo) => subirEm(subidos, BUCKET, caminho, a);
  const caminhoNf = c.nf ? await subir(`${id}/nf.pdf`, c.nf) : null;
  const caminhoBol = c.boleto ? await subir(`${id}/boleto.pdf`, c.boleto) : null;
  for (let i = 0; i < c.outros.length; i++) await subir(`${id}/outros/${i + 1}.pdf`, c.outros[i]);
  const linha: Record<string, unknown> = {
    id, message_id: e.messageId, remetente: e.remetente, assunto: e.assunto,
    cnpj_lido: dados.cnpj, valor_lido: dados.valor, numero_nota_lido: dados.numero, data_vencimento: null,
    caminho_pdf_nf: caminhoNf, caminho_pdf_boleto: caminhoBol, outros_anexos: c.outros.length,
  };
  if (e.dataRecebimento) linha.data_recebimento = e.dataRecebimento;
  const { data: gravada, error } = await db().from("financeiro_notas_triagem").insert(linha).select("fornecedor_id, fornecedor_achado_por").single();
  if (error) throw new Falha("Não foi possível gravar a nota: " + error.message, 500);
  return { ok: true, fila: "financeiro", id, fornecedor: gravada?.fornecedor_id ? gravada.fornecedor_achado_por : null, pdfs: subidos.length };
}

// ---------- "Mover para…" ----------
const FILAS: Record<string, { tabela: string; bucket: string; principal: RegExp }> = {
  financeiro: { tabela: "financeiro_notas_triagem", bucket: BUCKET, principal: /^(nf|boleto)\.pdf$/ },
  orcamentos: { tabela: "manutencao_orcamentos_triagem", bucket: BUCKET_ORC, principal: /^orcamento\.pdf$/ },
  multas: { tabela: "multas_triagem", bucket: BUCKET_MULTAS, principal: /^notificacao\.pdf$/ },
};
const estaPendente = (fila: string, t: Record<string, unknown>) => (fila === "financeiro" ? t.status_aprovacao : t.status) === "pendente";

// PDFs do item, na ordem: principal (nf antes de boleto), depois outros/1, 2…
async function pdfsDoItem(bucket: string, id: string) {
  const { data: raiz } = await admin.storage.from(bucket).list(id, { limit: 50 });
  const { data: outros } = await admin.storage.from(bucket).list(`${id}/outros`, { limit: 50 });
  const principais = (raiz || []).filter((f) => /\.pdf$/i.test(f.name)).map((f) => f.name).sort();   // boleto < nf: invertido abaixo
  const ordem = [...principais.filter((n) => n !== "boleto.pdf"), ...principais.filter((n) => n === "boleto.pdf")].map((n) => `${id}/${n}`);
  const extras = (outros || []).filter((f) => /\.pdf$/i.test(f.name)).map((f) => f.name)
    .sort((a, b) => parseInt(a) - parseInt(b)).map((n) => `${id}/outros/${n}`);
  const caminhos = [...ordem, ...extras];
  const pdfs: Anexo[] = [];
  for (const c of caminhos) {
    const { data: blob, error } = await admin.storage.from(bucket).download(c);
    if (error || !blob) throw new Falha("Não foi possível ler o PDF " + c, 500);
    pdfs.push({ nome: c.split("/").pop() || "anexo.pdf", tipo: "application/pdf", bytes: new Uint8Array(await blob.arrayBuffer()) });
  }
  return { caminhos, pdfs };
}

// quem está movendo: login da tela (conferido no banco com o próprio token) ou a chave de automação
async function quemMove(req: Request, fila: string, id: string) {
  const chave = req.headers.get("x-inbound-key") || "";
  if (chave) {
    if (!(await chaveValida(chave))) throw new Falha("Não autorizado.", 401);
    return { uid: null as string | null, nome: "Automação" };
  }
  const auth = req.headers.get("authorization") || "";
  if (!/^bearer /i.test(auth)) throw new Falha("Faça login para mover.", 401);
  const usuario = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await usuario.schema("frota").rpc("triagem_mover_autorizacao", { p_fila: fila, p_id: id });
  if (error) throw new Falha("Não foi possível conferir seu acesso (entre de novo).", 401);
  if (!data?.ok) throw new Falha(data?.motivo || "Sem permissão para mover.", 403);
  return { uid: data.uid as string, nome: (data.nome as string) || null };
}

async function mover(req: Request, teste: boolean, subidos: Subido[]) {
  const b = await req.json().catch(() => ({}));
  const de = String(b?.de || ""), para = String(b?.para || ""), id = String(b?.id || ""), motivo = corta(b?.motivo, 300);
  if (!FILAS[de] || !FILAS[para] || de === para) throw new Falha("Escolha a fila de origem e uma fila de destino diferente.");
  if (!UUID.test(id)) throw new Falha("Item inválido.");
  const quem = await quemMove(req, de, id);
  const { data: t, error } = await db().from(FILAS[de].tabela).select("*").eq("id", id).maybeSingle();
  if (error) throw new Falha(error.message, 500);
  if (!t) throw new Falha("Item não encontrado.", 404);
  if (!estaPendente(de, t)) throw new Falha("Só item pendente pode ser movido.", 409);

  const { caminhos, pdfs } = await pdfsDoItem(FILAS[de].bucket, id);
  if (!pdfs.length) throw new Falha("O item não tem PDF para mover.", 409);
  const textos = para === "financeiro" ? [] : await textosPorPdf(pdfs);
  const e: Origem = { messageId: t.message_id, remetente: t.remetente, assunto: t.assunto, dataRecebimento: t.data_recebimento, origem: "movida" };
  const det = "movida da " + ({ financeiro: "triagem financeira", orcamentos: "triagem de orçamentos", multas: "triagem de multas" } as Record<string, string>)[de]
    + (motivo ? ": " + motivo : "");
  // deno-lint-ignore no-explicit-any
  let r: any;
  if (para === "multas") r = await gravarMulta(e, pdfs, juntar(textos), det, teste, subidos);
  else if (para === "orcamentos") r = await gravarOrcamento(e, pdfs, textos, det, teste, subidos);
  else r = await gravarFinanceiro(e, pdfs, null, teste, subidos);
  if (teste) return { ...r, mover: { de, para, id, pdfs: caminhos.length, quem: quem.nome } };
  if (r.duplicado) throw new Falha("Este e-mail já está na fila de destino.", 409);
  const novos: string[] = r.ids || (r.id ? [r.id] : []);
  if (!novos.length) throw new Falha("Nada foi gravado no destino.", 500);

  try {
    const { error: e1 } = await db().from("triagem_movimentacoes").insert(novos.map((pid) => ({
      de_fila: de, de_id: id, para_fila: para, para_id: pid, message_id: t.message_id, remetente: t.remetente, assunto: t.assunto,
      pdfs: caminhos.length, motivo, movido_por: quem.uid, movido_por_nome: quem.nome,
    })));
    if (e1) throw new Falha("Não foi possível registrar a movimentação: " + e1.message, 500);
    const { error: e2 } = await db().from(FILAS[de].tabela).delete().eq("id", id);
    if (e2) throw new Falha("Não foi possível tirar o item da fila de origem: " + e2.message, 500);
  } catch (err) {
    await db().from(FILAS[para].tabela).delete().in("id", novos);   // desfaz o destino; os arquivos saem no catch geral
    throw err;
  }
  subidos.length = 0;   // destino gravado: não apagar os arquivos novos
  await admin.storage.from(FILAS[de].bucket).remove(caminhos);
  return { ok: true, movido: { de, para, de_id: id, para_ids: novos, pdfs: caminhos.length }, destino: r };
}

// ---------- resposta à oficina (O2): ?acao=responder_orcamento, corpo { id }, com o login de quem decidiu ----------
// Postmark quando houver os segredos POSTMARK_SERVER_TOKEN e POSTMARK_FROM (remetente verificado no Postmark):
// To = remetente do orçamento, Cc = frota@, Reply-To = e-mail de quem decidiu. Sem os segredos (ou se o Postmark
// recusar), grava canal "mailto" e devolve os dados para a tela abrir o e-mail da própria pessoa.
const POSTMARK_TOKEN = Deno.env.get("POSTMARK_SERVER_TOKEN") || "";
const POSTMARK_FROM = Deno.env.get("POSTMARK_FROM") || "";
const FROTA_EMAIL = "frota@beepsaude.com.br";
async function responderOrcamento(req: Request) {
  const b = await req.json().catch(() => ({}));
  const id = String(b?.id || "");
  if (!UUID.test(id)) throw new Falha("Orçamento inválido.");
  const auth = req.headers.get("authorization") || "";
  if (!/^bearer /i.test(auth)) throw new Falha("Faça login para responder.", 401);
  const usuario = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: p, error } = await usuario.schema("frota").rpc("orcamento_resposta_preparar", { p_id: id });
  if (error) throw new Falha("Não foi possível conferir seu acesso (entre de novo).", 401);
  if (!p?.ok) throw new Falha(p?.motivo || "Sem permissão para responder.", 409);
  const tabela = () => db().from("manutencao_orcamentos_triagem");
  const manual = async (erro: string | null) => {
    await tabela().update({ resposta_canal: "mailto", resposta_enviada_em: new Date().toISOString(), resposta_erro: erro }).eq("id", id);
    return { ok: true, canal: "mailto", erro, para: p.para, cc: FROTA_EMAIL, assunto: p.assunto, texto: p.texto };
  };
  if (!POSTMARK_TOKEN || !POSTMARK_FROM) return manual(null);
  const r = await fetch("https://api.postmarkapp.com/email", {
    method: "POST",
    headers: { "Accept": "application/json", "Content-Type": "application/json", "X-Postmark-Server-Token": POSTMARK_TOKEN },
    body: JSON.stringify({ From: POSTMARK_FROM, To: p.para, Cc: FROTA_EMAIL, ReplyTo: p.responder_para || FROTA_EMAIL, Subject: p.assunto,
      TextBody: p.texto + "\n\n—\nRespondido por " + (p.nome || "Frota") + (p.responder_para ? " <" + p.responder_para + ">" : "") + " pela Beep Fleet.",
      MessageStream: "outbound" }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.ErrorCode) return manual(("Postmark: " + (j.Message || "HTTP " + r.status)).slice(0, 300));
  await tabela().update({ resposta_canal: "postmark", resposta_enviada_em: new Date().toISOString(), resposta_erro: null }).eq("id", id);
  return { ok: true, canal: "postmark", para: p.para };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const subidos: Subido[] = [];
  try {
    if (req.method !== "POST") throw new Falha("Use POST.", 405);
    const url = new URL(req.url);
    const teste = req.headers.get("x-inbound-teste") === "1" || url.searchParams.get("teste") === "1";
    const acao = url.searchParams.get("acao") || req.headers.get("x-inbound-acao");
    if (acao === "mover") return json(await mover(req, teste, subidos));   // autenticação própria (login ou chave)
    if (acao === "responder_orcamento") return json(await responderOrcamento(req));   // só com login

    if (!(await chaveValida(chaveRecebida(req)))) throw new Falha("Não autorizado.", 401);
    const email = await lerEmail(req);
    const c = classificar(email.anexos);
    const origem: Origem = { messageId: email.messageId, remetente: email.remetente, assunto: email.assunto, origem: "email" };
    const pdfsTodos = [c.nf, c.boleto, ...c.outros].filter(Boolean) as Anexo[];
    const textos = await textosPorPdf(pdfsTodos);
    const textoPdf = juntar(textos);
    const nomes = email.anexos.map((a) => a.nome);

    // 1. multa?
    const det = R.ehEmailDeMulta(email.assunto, nomes, textoPdf);
    if (det.multa) return json(await gravarMulta(origem, pdfsTodos, textoPdf, det.motivo, teste, subidos));

    // 2. orçamento de oficina? (só com PDF; NF/DANFE/boleto nunca é orçamento)
    const orc = R.ehEmailDeOrcamento(email.assunto, nomes, textoPdf);
    if (orc.orcamento && pdfsTodos.length) return json(await gravarOrcamento(origem, pdfsTodos, textos, orc.motivo, teste, subidos));

    // 3. financeiro
    return json(await gravarFinanceiro(origem, email.anexos, c.xml, teste, subidos, email.formato));
  } catch (e) {
    for (const bk of [BUCKET, BUCKET_MULTAS, BUCKET_ORC]) {   // não deixa arquivo sem linha
      const lista = subidos.filter((s) => s.bucket === bk).map((s) => s.caminho);
      if (lista.length) await admin.storage.from(bk).remove(lista).catch(() => {});
    }
    const st = e instanceof Falha ? e.status : 500;
    console.error("inbound-triagem-nfs:", st, (e as Error).message);   // sem conteúdo do e-mail no log
    return json({ erro: (e as Error).message }, st);
  }
});
