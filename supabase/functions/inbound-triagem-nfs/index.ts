// Edge Function `inbound-triagem-nfs` — webhook que recebe os e-mails de NF/boleto (Triagem de notas, T1).
//
// ESTADO: ESQUELETO. Publicado, mas sem efeito até existir o segredo INBOUND_TRIAGEM_CHAVE e um serviço
// de e-mail apontando para cá (ainda a escolher: SendGrid Inbound Parse, Mailgun Routes, Postmark Inbound,
// Cloudflare Email Workers…). Leitura do PDF (texto) fica para a próxima etapa; hoje lê CNPJ/valor/
// vencimento/número só do XML da NF-e/NFS-e (quando vem anexo) e o CNPJ do assunto.
//
// Segurança:
//  - verify_jwt = false (quem chama é o serviço de e-mail, sem login). Toda chamada precisa da chave
//    INBOUND_TRIAGEM_CHAVE (segredo da função) no cabeçalho x-inbound-key ou em ?chave= (alguns serviços
//    só aceitam URL). Comparação em tempo constante. Sem a chave configurada, recusa tudo.
//  - grava com service_role (a tabela não aceita INSERT de ninguém logado); arquivos no bucket PRIVADO
//    notas-triagem em {id}/nf.pdf, {id}/boleto.pdf, {id}/nf.xml — a tela gera link assinado na hora.
//  - não grava o corpo do e-mail; só remetente, assunto, id da mensagem e os anexos.
//
// Formatos aceitos:
//  - multipart/form-data (padrão dos serviços de inbound parse): campos from/sender, subject,
//    headers ou message-id, e os arquivos anexos;
//  - JSON normalizado: { remetente, assunto, message_id, anexos: [{ nome, tipo, base64 }] }.
// Idempotente: o mesmo message_id não cria segunda linha (devolve a existente).
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHAVE = Deno.env.get("INBOUND_TRIAGEM_CHAVE") || "";
const BUCKET = "notas-triagem";
const MAX_BYTES = 10 * 1024 * 1024;
const MAX_ANEXOS = 10;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = () => admin.schema("frota");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
class Falha extends Error { constructor(msg: string, public status = 400) { super(msg); } }

function igualSeguro(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let dif = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) dif |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return dif === 0;
}

type Anexo = { nome: string; tipo: string; bytes: Uint8Array };
type Email = { remetente: string | null; assunto: string | null; messageId: string | null; anexos: Anexo[] };

// ---------- leitura do e-mail (multipart ou JSON) ----------
async function lerEmail(req: Request): Promise<Email> {
  const ct = req.headers.get("content-type") || "";
  if (ct.includes("multipart/form-data")) {
    const form = await req.formData();
    const anexos: Anexo[] = [];
    for (const [, v] of form.entries()) {
      if (v instanceof File && anexos.length < MAX_ANEXOS) {
        anexos.push({ nome: v.name || "anexo", tipo: v.type || "", bytes: new Uint8Array(await v.arrayBuffer()) });
      }
    }
    const cab = String(form.get("headers") || "");
    const mid = String(form.get("message-id") || form.get("Message-Id") || "") || (cab.match(/^message-id:\s*(.+)$/im)?.[1] ?? "");
    return {
      remetente: limparRemetente(String(form.get("from") || form.get("sender") || "")),
      assunto: String(form.get("subject") || "").slice(0, 300) || null,
      messageId: mid.trim().slice(0, 300) || null,
      anexos,
    };
  }
  const b = await req.json().catch(() => { throw new Falha("Corpo inválido."); });
  return {
    remetente: limparRemetente(String(b.remetente || "")),
    assunto: String(b.assunto || "").slice(0, 300) || null,
    messageId: String(b.message_id || "").trim().slice(0, 300) || null,
    anexos: (Array.isArray(b.anexos) ? b.anexos : []).slice(0, MAX_ANEXOS).map((a: any) => ({
      nome: String(a.nome || "anexo"), tipo: String(a.tipo || ""),
      bytes: Uint8Array.from(atob(String(a.base64 || "")), (c) => c.charCodeAt(0)),
    })),
  };
}
// "Fulano <nf@empresa.com>" → "nf@empresa.com" (só o e-mail)
function limparRemetente(s: string) {
  const m = s.match(/[^\s<>"]+@[^\s<>"]+/);
  return m ? m[0].toLowerCase().slice(0, 200) : null;
}

// ---------- classificação dos anexos ----------
function ehPdf(a: Anexo) { return /pdf/i.test(a.tipo) || /\.pdf$/i.test(a.nome); }
function ehXml(a: Anexo) { return /xml/i.test(a.tipo) || /\.xml$/i.test(a.nome); }
function classificar(anexos: Anexo[]) {
  const pdfs = anexos.filter((a) => ehPdf(a) && a.bytes.length <= MAX_BYTES);
  const boleto = pdfs.find((a) => /boleto|bol\b|fatura|cobran/i.test(a.nome)) || null;
  const nf = pdfs.find((a) => a !== boleto && /nf|nota|danfe|nfs/i.test(a.nome)) || pdfs.find((a) => a !== boleto) || null;
  const xml = anexos.find((a) => ehXml(a) && a.bytes.length <= MAX_BYTES) || null;
  const usados = [boleto, nf, xml].filter(Boolean).length;
  return { nf, boleto, xml, outros: anexos.length - usados };
}

// ---------- leitura dos dados (XML da NF-e/NFS-e; PDF fica para a próxima etapa) ----------
function lerDados(xml: Anexo | null, assunto: string | null) {
  const d: { cnpj: string | null; valor: number | null; vencimento: string | null; numero: string | null } =
    { cnpj: null, valor: null, vencimento: null, numero: null };
  if (xml) {
    const t = new TextDecoder().decode(xml.bytes);
    const tag = (re: RegExp) => t.match(re)?.[1]?.trim() || null;
    // emitente/prestador primeiro; senão o primeiro CNPJ do arquivo
    d.cnpj = tag(/<emit>[\s\S]*?<CNPJ>(\d{14})<\/CNPJ>/i) || tag(/<(?:PrestadorServico|Prestador)[\s\S]*?<Cnpj>(\d{14})<\/Cnpj>/i) || tag(/<CNPJ>(\d{14})<\/CNPJ>/i);
    const v = tag(/<vNF>([\d.]+)<\/vNF>/i) || tag(/<ValorLiquidoNfse>([\d.]+)<\//i) || tag(/<ValorServicos>([\d.]+)<\//i);
    d.valor = v ? Number(v) : null;
    d.vencimento = tag(/<dVenc>(\d{4}-\d{2}-\d{2})<\/dVenc>/i);
    d.numero = tag(/<nNF>(\d+)<\/nNF>/i) || tag(/<Numero>(\d+)<\/Numero>/i);
  }
  if (!d.cnpj && assunto) {
    const m = assunto.match(/\b(\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2})\b/);
    if (m) d.cnpj = m[1].replace(/\D/g, "");
  }
  if (d.valor != null && !(d.valor > 0)) d.valor = null;
  return d;
}

async function subir(caminho: string, a: Anexo, tipo: string) {
  const { error } = await admin.storage.from(BUCKET).upload(caminho, a.bytes, { contentType: tipo, upsert: false });
  if (error) throw new Falha("Não foi possível guardar o anexo: " + error.message, 500);
  return caminho;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new Falha("Use POST.", 405);
    if (!CHAVE) throw new Falha("Webhook ainda não configurado.", 503);
    const recebida = req.headers.get("x-inbound-key") || new URL(req.url).searchParams.get("chave") || "";
    if (!igualSeguro(recebida, CHAVE)) throw new Falha("Não autorizado.", 401);

    const email = await lerEmail(req);
    if (email.messageId) {
      const { data: ja } = await db().from("financeiro_notas_triagem").select("id").eq("message_id", email.messageId).maybeSingle();
      if (ja) return json({ ok: true, duplicado: true, id: ja.id });
    }
    const { nf, boleto, xml, outros } = classificar(email.anexos);
    if (!nf && !boleto && !xml) return json({ ok: true, ignorado: "e-mail sem PDF nem XML de nota" });

    const id = crypto.randomUUID();
    const dados = lerDados(xml, email.assunto);
    const caminhoNf = nf ? await subir(`${id}/nf.pdf`, nf, "application/pdf") : null;
    const caminhoBol = boleto ? await subir(`${id}/boleto.pdf`, boleto, "application/pdf") : null;
    if (xml) await subir(`${id}/nf.xml`, xml, "application/xml");

    const { error } = await db().from("financeiro_notas_triagem").insert({
      id, message_id: email.messageId, remetente: email.remetente, assunto: email.assunto,
      cnpj_lido: dados.cnpj, valor_lido: dados.valor, data_vencimento: dados.vencimento, numero_nota_lido: dados.numero,
      caminho_pdf_nf: caminhoNf, caminho_pdf_boleto: caminhoBol, outros_anexos: outros + (xml ? 1 : 0),
    });
    if (error) throw new Falha("Não foi possível gravar a nota: " + error.message, 500);
    return json({ ok: true, id, lidos: { cnpj: !!dados.cnpj, valor: dados.valor != null, vencimento: !!dados.vencimento } });
  } catch (e) {
    const st = e instanceof Falha ? e.status : 500;
    console.error("inbound-triagem-nfs:", (e as Error).message);   // sem conteúdo do e-mail no log
    return json({ erro: (e as Error).message }, st);
  }
});
