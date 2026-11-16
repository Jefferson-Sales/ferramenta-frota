// Edge Function `inbound-triagem-nfs` — webhook que recebe os e-mails de NF/boleto enviados para frota@ e
// coloca cada um na Triagem de notas (T1 13/11/2026; T2 16/11/2026).
//
// Fluxo: fornecedor → frota@beepsaude.com.br → cópia para o endereço de inbound do provedor (recomendado: Postmark)
// → POST aqui → PDFs no bucket PRIVADO notas-triagem → linha em frota.financeiro_notas_triagem (status pendente).
//
// Regras (pedido do Jefferson, 16/11/2026):
//  - guarda SÓ os PDFs: o 1º com cara de boleto vira {id}/boleto.pdf, o 1º outro vira {id}/nf.pdf, os demais
//    {id}/outros/N.pdf. E-mail sem PDF é ignorado (responde 200 para o provedor não reenviar).
//  - fornecedor: o banco procura (gatilho tg_triagem_notas → triagem_achar_fornecedor) pelo CNPJ lido do XML da
//    NF-e/NFS-e ou do assunto e, sem CNPJ, pelo e-mail do remetente = contato_email de um fornecedor ativo.
//    O XML é lido só na memória (CNPJ, número, valor); não é guardado.
//  - vencimento fica em branco: é conferido na tela (ou por OCR, depois).
//
// Segurança:
//  - verify_jwt = false (quem chama é o provedor de e-mail). Toda chamada precisa da chave do Vault
//    `inbound_triagem_chave` (conferida no banco por frota.verificar_inbound_triagem, só service_role), enviada
//    de um destes jeitos: cabeçalho x-inbound-key, ?chave= na URL, ou senha do Basic Auth (https://x:CHAVE@…,
//    formato do Postmark). Sem chave certa: 401.
//  - grava com service_role (a tabela não aceita INSERT de ninguém logado); guarda o CAMINHO do arquivo, nunca link.
//  - não guarda o corpo do e-mail nem o escreve no log; só remetente, assunto, id da mensagem e os PDFs.
//
// Formatos aceitos:
//  - JSON do Postmark Inbound (FromFull, Subject, Headers, MessageID, Attachments[{Name, ContentType, Content}]);
//  - multipart/form-data (SendGrid Inbound Parse, Mailgun Routes): from/sender, subject, headers ou Message-Id, arquivos;
//  - JSON normalizado: { remetente, assunto, message_id, anexos: [{ nome, tipo, base64 }] }.
// Modo teste (cabeçalho x-inbound-teste: 1 ou ?teste=1): lê tudo e responde o que faria, sem gravar nada.
// Idempotente: o mesmo message_id não cria segunda linha.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "notas-triagem";
const MAX_BYTES = 10 * 1024 * 1024;   // limite do bucket
const MAX_ANEXOS = 15;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }

type Anexo = { nome: string; tipo: string; bytes: Uint8Array };
type Email = { remetente: string | null; assunto: string | null; messageId: string | null; anexos: Anexo[]; formato: string };

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

Deno.serve(async (req) => {
  const subidos: string[] = [];
  try {
    if (req.method !== "POST") throw new Falha("Use POST.", 405);
    if (!(await chaveValida(chaveRecebida(req)))) throw new Falha("Não autorizado.", 401);
    const teste = req.headers.get("x-inbound-teste") === "1" || new URL(req.url).searchParams.get("teste") === "1";

    const email = await lerEmail(req);
    const c = classificar(email.anexos);
    const dados = lerDados(c.xml, email.assunto);

    if (teste) {
      const { data: ach } = await db().rpc("triagem_achar_fornecedor", { p_cnpj: dados.cnpj, p_email: email.remetente });
      const f = Array.isArray(ach) ? ach[0] : null;
      return json({ ok: true, teste: true, formato: email.formato, remetente: email.remetente, assunto: email.assunto, message_id: email.messageId,
        nf: c.nf?.nome ?? null, boleto: c.boleto?.nome ?? null, outros_pdfs: c.outros.map((a) => a.nome),
        ignorados_nao_pdf: c.ignorados, pdfs_grandes_demais: c.grandes, lidos: dados,
        fornecedor: f ? { id: f.fornecedor_id, achado_por: f.achado_por } : null });
    }

    if (email.messageId) {
      const { data: ja } = await db().from("financeiro_notas_triagem").select("id").eq("message_id", email.messageId).maybeSingle();
      if (ja) return json({ ok: true, duplicado: true, id: ja.id });
    }
    if (!c.nf && !c.boleto) return json({ ok: true, ignorado: "e-mail sem anexo PDF", pdfs_grandes_demais: c.grandes });

    const id = crypto.randomUUID();
    const subir = async (caminho: string, a: Anexo) => {
      const { error } = await admin.storage.from(BUCKET).upload(caminho, a.bytes, { contentType: "application/pdf", upsert: false });
      if (error) throw new Falha("Não foi possível guardar o anexo: " + error.message, 500);
      subidos.push(caminho); return caminho;
    };
    const caminhoNf = c.nf ? await subir(`${id}/nf.pdf`, c.nf) : null;
    const caminhoBol = c.boleto ? await subir(`${id}/boleto.pdf`, c.boleto) : null;
    for (let i = 0; i < c.outros.length; i++) await subir(`${id}/outros/${i + 1}.pdf`, c.outros[i]);

    const { data: linha, error } = await db().from("financeiro_notas_triagem").insert({
      id, message_id: email.messageId, remetente: email.remetente, assunto: email.assunto,
      cnpj_lido: dados.cnpj, valor_lido: dados.valor, numero_nota_lido: dados.numero, data_vencimento: null,
      caminho_pdf_nf: caminhoNf, caminho_pdf_boleto: caminhoBol, outros_anexos: c.outros.length,
    }).select("fornecedor_id, fornecedor_achado_por").single();
    if (error) throw new Falha("Não foi possível gravar a nota: " + error.message, 500);
    return json({ ok: true, id, fornecedor: linha?.fornecedor_id ? linha.fornecedor_achado_por : null, pdfs: subidos.length });
  } catch (e) {
    if (subidos.length) await admin.storage.from(BUCKET).remove(subidos).catch(() => {});   // não deixa arquivo sem linha
    const st = e instanceof Falha ? e.status : 500;
    console.error("inbound-triagem-nfs:", st, (e as Error).message);   // sem conteúdo do e-mail no log
    return json({ erro: (e as Error).message }, st);
  }
});
