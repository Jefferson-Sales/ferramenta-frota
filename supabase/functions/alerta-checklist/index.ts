// Edge Function `alerta-checklist` — e-mail de alerta quando um checklist traz anomalia NOVA.
// Chamada só por automação interna (gatilho do banco e cron), com x-automation-key validada
// contra o Vault (frota.verificar_chave_checklist). verify_jwt = false na plataforma.
//
// Modos (POST JSON):
//   { modo: "checklist", checklist_id }  — envia o alerta desse checklist (gatilho)
//   { modo: "pendentes" }                — reenvia o que ficou pendente/erro (cron 15 min)
//   { modo: "teste", checklist_id }      — manda o e-mail desse checklist para a PRÓPRIA conta
//                                           remetente (SMTP_USER), sem marcar nada no banco
//   { modo: "diagnostico" }              — só informa se os segredos estão configurados
//   { modo: "cadastro", cadastro_id }    — aviso de auto-cadastro de motorista aguardando aprovação
//                                           (sem CPF/RG/CNH/senha no e-mail; o admin vê tudo no painel)
//
// SMTP: Google Workspace, smtp.gmail.com:465 (TLS direto; Edge Functions bloqueiam 25/587).
// Anomalia crítica só gera e-mail: não muda status do veículo nem abre OS.
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SMTP_USER = Deno.env.get("SMTP_USER") || "";
const SMTP_PASS = Deno.env.get("SMTP_PASS") || "";
const ALERTA_PARA = Deno.env.get("ALERTA_PARA") || "frota@beepsaude.com.br";
const PAINEL_URL = "https://jefferson-sales.github.io/ferramenta-frota/";
const FOTO_VALIDADE_S = 7 * 24 * 3600;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
const db = () => admin.schema("frota");

const SEV: Record<string, { label: string; cor: string; o: number }> = {
  critica: { label: "CRÍTICA", cor: "#c23b3b", o: 0 },
  alta: { label: "Alta", cor: "#c23b3b", o: 1 },
  media: { label: "Média", cor: "#a8690a", o: 2 },
  baixa: { label: "Baixa", cor: "#5c645d", o: 3 },
};
const TIPO: Record<string, string> = { retirada: "Retirada", devolucao: "Devolução", inspecao_tecnica: "Inspeção técnica" };
const RES: Record<string, string> = { ok: "OK", atencao: "Atenção", reparo_necessario: "Reparo necessário", urgente: "URGENTE — não rodar" };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const dataBR = (iso: string) => new Date(iso).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" });
const km = (v: unknown) => v == null ? "—" : Number(v).toLocaleString("pt-BR") + " km";

async function montarEmail(checklistId: string, incluirDescartadas: boolean) {
  const { data: c, error } = await db().from("checklists")
    .select("id, tipo, enviado_em, km, nivel_combustivel, bateria_pct, colaborador_nome, colaborador_matricula, resultado, observacoes, preenchido_por, veiculos(placa, modelo), hubs(nome)")
    .eq("id", checklistId).maybeSingle();
  if (error) throw error;
  if (!c) throw new Error("checklist não encontrado");

  let q = db().from("checklist_anomalias")
    .select("id, grupo, item_codigo, subtipo, descricao, severidade, status, checklist_fotos(storage_path)")
    .eq("checklist_id", checklistId).eq("nova", true);
  if (!incluirDescartadas) q = q.neq("status", "descartada");
  const { data: anoms, error: e2 } = await q;
  if (e2) throw e2;
  if (!anoms || !anoms.length) return null;

  const { data: cat } = await db().from("checklist_itens_catalogo").select("codigo, descricao, grupo, grupo_nome");
  const itens: Record<string, any> = {}, grupos: Record<string, string> = {};
  (cat || []).forEach((i: any) => { itens[i.codigo] = i; grupos[i.grupo] = i.grupo_nome; });

  const paths = anoms.flatMap((a: any) => (a.checklist_fotos || []).map((f: any) => f.storage_path));
  const urls: Record<string, string> = {};
  if (paths.length) {
    const { data: signed } = await admin.storage.from("checklist-fotos").createSignedUrls(paths, FOTO_VALIDADE_S);
    (signed || []).forEach((s: any) => { if (s.signedUrl) urls[s.path] = s.signedUrl; });
  }

  anoms.sort((a: any, b: any) => SEV[a.severidade].o - SEV[b.severidade].o);
  const v: any = c.veiculos || {}, hub: any = c.hubs || {};
  const criticas = anoms.filter((a: any) => a.severidade === "critica").length;
  const n = anoms.length;
  const assunto = (criticas ? "[URGENTE] " : "") + `Checklist ${v.placa}: ${n} anomalia${n > 1 ? "s" : ""} nova${n > 1 ? "s" : ""}` +
    (criticas ? ` (${criticas} crítica${criticas > 1 ? "s" : ""})` : "");
  const energia = c.bateria_pct != null ? `bateria ${c.bateria_pct}%` : c.nivel_combustivel ? `combustível ${c.nivel_combustivel}` : "";
  const quem = `${c.colaborador_nome || "—"} (matrícula ${c.colaborador_matricula || "—"}${c.preenchido_por ? ", auxiliar de frota" : ""})`;

  const linhas = anoms.map((a: any) => {
    const it = a.item_codigo ? itens[a.item_codigo] : null;
    const item = (it ? it.descricao : "Outro problema") + (a.subtipo ? " — " + a.subtipo : "");
    const fotos = (a.checklist_fotos || []).map((f: any) => urls[f.storage_path]).filter(Boolean);
    return { sev: SEV[a.severidade], grupo: grupos[a.grupo] || a.grupo, item, desc: a.descricao || "", fotos };
  });

  const texto = [
    assunto, "",
    `Placa: ${v.placa} — ${v.modelo || ""}`,
    `Hub: ${hub.nome || "—"}`,
    `Checklist: ${TIPO[c.tipo] || c.tipo} em ${dataBR(c.enviado_em)}`,
    `Preenchido por: ${quem}`,
    `KM: ${km(c.km)}${energia ? " · " + energia : ""}`,
    `Resultado do checklist: ${RES[c.resultado] || c.resultado}`, "",
    "Anomalias novas:",
    ...linhas.map((l) => `- [${l.sev.label}] ${l.grupo} / ${l.item}${l.desc ? ": " + l.desc : ""}` +
      (l.fotos.length ? `\n  Foto: ${l.fotos.join("\n  Foto: ")}` : "")),
    "", c.observacoes ? `Observações: ${c.observacoes}\n` : "",
    `Histórico e fotos no painel: ${PAINEL_URL} (módulo Qualidade da Frota)`,
    `Links das fotos valem 7 dias.`,
  ].join("\n");

  const td = 'style="padding:8px 10px;border-bottom:1px solid #e2e0d5;vertical-align:top;font-size:14px"';
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#1a231f;max-width:640px">
<h2 style="margin:0 0 4px;font-size:19px">${criticas ? '<span style="color:#c23b3b">URGENTE · </span>' : ""}Checklist ${esc(v.placa)} — ${n} anomalia${n > 1 ? "s" : ""} nova${n > 1 ? "s" : ""}</h2>
<p style="margin:0 0 14px;color:#5c645d;font-size:14px">${esc(v.modelo || "")} · Hub ${esc(hub.nome || "—")}</p>
<table style="border-collapse:collapse;font-size:14px;margin-bottom:14px">
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Checklist</td><td>${esc(TIPO[c.tipo] || c.tipo)} em ${esc(dataBR(c.enviado_em))}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Preenchido por</td><td>${esc(quem)}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">KM</td><td>${esc(km(c.km))}${energia ? " · " + esc(energia) : ""}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Resultado</td><td><b>${esc(RES[c.resultado] || c.resultado)}</b></td></tr>
</table>
<table style="border-collapse:collapse;width:100%;border:1px solid #e2e0d5">
<tr style="background:#efeee7"><th align="left" ${td}>Severidade</th><th align="left" ${td}>Item</th><th align="left" ${td}>Descrição</th><th align="left" ${td}>Foto</th></tr>
${linhas.map((l) => `<tr><td ${td}><b style="color:${l.sev.cor}">${l.sev.label}</b></td><td ${td}>${esc(l.item)}<br><span style="color:#5c645d;font-size:12px">${esc(l.grupo)}</span></td><td ${td}>${esc(l.desc) || "—"}</td><td ${td}>${l.fotos.map((u: string, i: number) => `<a href="${esc(u)}">Ver foto${l.fotos.length > 1 ? " " + (i + 1) : ""}</a>`).join("<br>") || "—"}</td></tr>`).join("\n")}
</table>
${c.observacoes ? `<p style="font-size:14px"><b>Observações:</b> ${esc(c.observacoes)}</p>` : ""}
<p style="font-size:13px;color:#5c645d;margin-top:16px">Histórico completo e fotos no <a href="${PAINEL_URL}">painel da frota</a> (módulo Qualidade da Frota). Links das fotos valem 7 dias.<br>
Alerta automático do Checklist do Veículo — não responda este e-mail.</p></div>`;

  return { assunto, texto, html };
}

async function enviar(para: string, m: { assunto: string; texto: string; html: string }) {
  const client = new SMTPClient({
    connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: SMTP_USER, password: SMTP_PASS } },
  });
  try {
    await client.send({ from: `Checklist da Frota <${SMTP_USER}>`, to: para, subject: m.assunto, content: m.texto, html: m.html });
  } finally {
    // close() do denomailer não devolve Promise; erro ao fechar não pode virar "falha de envio"
    // (senão o e-mail já entregue seria marcado como erro e o cron reenviaria).
    try { await client.close(); } catch (_) { /* ignora */ }
  }
}

async function avisarCadastro(cadastroId: string) {
  const { data: c, error } = await db().from("motoristas_cadastros")
    .select("id, nome, matricula, criado_em, possui_senha, status, alerta_status, hubs(nome)").eq("id", cadastroId).maybeSingle();
  if (error) throw error;
  if (!c) return { cadastro_id: cadastroId, resultado: "nao_encontrado" };
  if (c.alerta_status === "enviado") return { cadastro_id: cadastroId, resultado: "ja_tratado" };
  const hub: any = c.hubs || {};
  const assunto = `Cadastro de motorista aguardando aprovação: ${c.nome}`;
  const texto = [assunto, "", `Nome: ${c.nome}`, `Matrícula informada: ${c.matricula} (confira no RH antes de aprovar)`,
    `Hub: ${hub.nome || "—"}`, `Enviado em: ${dataBR(c.criado_em)}`,
    `Senha de abastecimento: ${c.possui_senha ? "já possui (informou a atual)" : "não possui (informou a que deseja cadastrar)"}`, "",
    `Aprovar ou reprovar no painel: ${PAINEL_URL} (menu do seu nome → Cadastros de motoristas; só admin).`,
    "Documentos e dados pessoais ficam só no painel, não neste e-mail."].join("\n");
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#1a231f;max-width:600px">
<h2 style="margin:0 0 10px;font-size:19px">Cadastro de motorista aguardando aprovação</h2>
<table style="border-collapse:collapse;font-size:14px;margin-bottom:14px">
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Nome</td><td><b>${esc(c.nome)}</b></td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Matrícula informada</td><td>${esc(c.matricula)} <span style="color:#5c645d">(confira no RH antes de aprovar)</span></td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Hub</td><td>${esc(hub.nome || "—")}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Enviado em</td><td>${esc(dataBR(c.criado_em))}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#5c645d">Senha de abastecimento</td><td>${c.possui_senha ? "já possui" : "não possui — pediu uma nova"}</td></tr>
</table>
<p style="font-size:14px">Aprove ou reprove no <a href="${PAINEL_URL}">painel da frota</a> (menu do seu nome → <b>Cadastros de motoristas</b>; só admin).</p>
<p style="font-size:13px;color:#5c645d">Documentos e dados pessoais ficam só no painel, não neste e-mail. Aviso automático — não responda.</p></div>`;
  try {
    await enviar(ALERTA_PARA, { assunto, texto, html });
    await db().from("motoristas_cadastros").update({ alerta_status: "enviado", alerta_erro: null }).eq("id", cadastroId);
    return { cadastro_id: cadastroId, resultado: "enviado", para: ALERTA_PARA };
  } catch (e) {
    const msg = (e as Error).message || String(e);
    await db().from("motoristas_cadastros").update({ alerta_status: "erro", alerta_erro: msg.slice(0, 500) }).eq("id", cadastroId);
    return { cadastro_id: cadastroId, resultado: "erro", erro: msg };
  }
}

async function processar(checklistId: string) {
  const { data: reservado, error } = await db().rpc("reservar_alerta_checklist", { p_id: checklistId });
  if (error) throw error;
  if (!reservado) return { checklist_id: checklistId, resultado: "ja_tratado" };
  try {
    const m = await montarEmail(checklistId, false);
    if (!m) {
      await db().from("checklists").update({ alerta_status: "ignorado", alerta_erro: "sem anomalias novas a alertar (descartadas)", alerta_reservado_em: null }).eq("id", checklistId);
      return { checklist_id: checklistId, resultado: "ignorado" };
    }
    await enviar(ALERTA_PARA, m);
    await db().from("checklists").update({ alerta_status: "enviado", alerta_enviado_em: new Date().toISOString(), alerta_erro: null, alerta_reservado_em: null }).eq("id", checklistId);
    return { checklist_id: checklistId, resultado: "enviado", para: ALERTA_PARA };
  } catch (e) {
    const msg = (e as Error).message || String(e);
    await db().from("checklists").update({ alerta_status: "erro", alerta_erro: msg.slice(0, 500), alerta_reservado_em: null }).eq("id", checklistId);
    return { checklist_id: checklistId, resultado: "erro", erro: msg };
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const chave = req.headers.get("x-automation-key") || "";
    const { data: ok } = chave ? await db().rpc("verificar_chave_checklist", { chave }) : { data: false };
    if (ok !== true) return json({ error: "Não autorizado." }, 401);

    const body = await req.json().catch(() => ({}));
    if (body.modo === "diagnostico") {
      return json({ smtp_user_definido: !!SMTP_USER, smtp_pass_definido: !!SMTP_PASS, remetente: SMTP_USER || null, para: ALERTA_PARA });
    }
    if (!SMTP_USER || !SMTP_PASS) return json({ error: "Segredos SMTP_USER/SMTP_PASS não configurados." }, 500);

    if (body.modo === "teste") {
      const m = await montarEmail(String(body.checklist_id || ""), true);
      if (!m) return json({ error: "checklist sem anomalias novas" }, 400);
      await enviar(SMTP_USER, { ...m, assunto: "[TESTE] " + m.assunto });
      return json({ resultado: "teste_enviado", para: SMTP_USER, assunto: "[TESTE] " + m.assunto });
    }
    if (body.modo === "checklist") return json(await processar(String(body.checklist_id || "")));
    if (body.modo === "cadastro") return json(await avisarCadastro(String(body.cadastro_id || "")));
    if (body.modo === "pendentes") {
      const { data: ids, error } = await db().rpc("listar_alertas_pendentes");
      if (error) throw error;
      const resultados = [];
      for (const id of (ids || []) as string[]) resultados.push(await processar(id));
      return json({ processados: resultados.length, resultados });
    }
    return json({ error: "Modo desconhecido." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 500);
  }
});
