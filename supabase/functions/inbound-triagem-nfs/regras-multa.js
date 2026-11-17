// GERADO por ferramentas/gerar-regras-multa.js a partir de /regras.js — não editar aqui.
(function (global) {
  function finNorm(s) {
    return String(s == null ? "" : s).normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
  }
  // ---------------------------------------------------------------- Triagem de multas (M1)
  // Usado no navegador e na Edge Function inbound-triagem-nfs (que leva uma cópia deste arquivo).
  // Assunto e nome do anexo: as palavras pedidas pelo Jefferson. Texto do PDF: só expressões de notificação — boleto de
  // fornecedor traz "multa de 2% após o vencimento" e não pode cair na fila de multas.
  var MULTA_PALAVRAS = /\b(INFRACAO|INFRACOES|AUTUACAO|AUTUACOES|PENALIDADE|PENALIDADES|AIT|DETRAN|DER|DNIT|MULTA|MULTAS)\b/;
  var MULTA_TEXTO_FORTE = /(AUTO DE INFRACAO|NOTIFICACAO D[AE] AUTUACAO|NOTIFICACAO D[AE] PENALIDADE|INFRACAO DE TRANSITO|RENAINF|CODIGO DA INFRACAO|NOTIFICACAO DE INFRACAO)/;
  function ehEmailDeMulta(assunto, nomesAnexos, texto) {
    var a = finNorm(assunto), m = a.match(MULTA_PALAVRAS);
    if (m) return { multa: true, motivo: "assunto: " + m[1].toLowerCase() };
    var nomes = (nomesAnexos || []).map(function(n){ return finNorm(String(n || "").replace(/\.[a-z0-9]+$/i, "").replace(/[_\-.]+/g, " ")); });
    for (var i = 0; i < nomes.length; i++) { var mn = nomes[i].match(MULTA_PALAVRAS); if (mn) return { multa: true, motivo: "anexo: " + mn[1].toLowerCase() }; }
    var t = finNorm(texto), mt = t.match(MULTA_TEXTO_FORTE);
    if (mt) return { multa: true, motivo: "texto do PDF: " + mt[1].toLowerCase() };
    return { multa: false, motivo: null };
  }
  // todas as datas do texto (dd/mm/aaaa, com hora logo depois se houver), com o trecho antes delas: "bloqueada" quando
  // o trecho fala de emissão/postagem/limite/vencimento/prazo/notificação/defesa/recurso/indicação; "infracao" quando fala
  // de infração/cometimento/ocorrência. Sem data marcada como infração, vale a mais antiga (a infração vem antes de tudo).
  function datasDaNotificacao(texto) {
    var s = String(texto || ""), re = /(\d{2})\/(\d{2})\/(\d{4})(?:\s*(?:às|as|-|,|\s)?\s*(\d{2})[:h](\d{2}))?/gi, m, out = [];
    while ((m = re.exec(s))) {
      var dia = +m[1], mes = +m[2]; if (dia < 1 || dia > 31 || mes < 1 || mes > 12) continue;
      var antes = finNorm(s.slice(Math.max(0, m.index - 60), m.index)), perto = antes.slice(-35);
      var hp = m[4] ? null : s.slice(m.index + m[0].length, m.index + m[0].length + 40).match(/^[^\d]{0,25}?(\d{2})[:h](\d{2})/i);
      out.push({ iso: m[3] + "-" + m[2] + "-" + m[1], hora: m[4] ? m[4] + ":" + m[5] : (hp ? hp[1] + ":" + hp[2] : null), antes: perto,
        bloqueada: /(EMISSAO|EMITID|POSTAGEM|POSTAD|EXPEDI|LIMITE|VENCIMENTO|VENCE|PRAZO|GERAD|IMPRESS|ATE O DIA|RECEBIMENTO|NOTIFICACAO|DEFESA|INTERPOSICAO|RECURSO|INDICACAO|CONDUTOR)/.test(perto),
        infracao: /(INFRACAO|COMETIMENTO|OCORRENCIA)/.test(perto) });
    }
    return out;
  }
  // placa (antiga ou Mercosul), data/hora da infração, nº do AIT, órgão, código e valor; null quando não acha
  function lerNotificacaoMulta(texto, assunto) {
    var t = finNorm(String(texto || "") + " " + String(assunto || "")), d = { placa: null, data_infracao: null, ait: null, orgao: null, codigo: null, valor: null };
    var PL = "([A-Z]{3}) ?([0-9])([A-Z0-9])([0-9]{2})";
    var mp = t.match(new RegExp("PLACA( DO VEICULO)? " + PL)) || t.match(new RegExp("\\b" + PL + "\\b"));
    if (mp) d.placa = mp[mp.length - 4] + mp[mp.length - 3] + mp[mp.length - 2] + mp[mp.length - 1];
    var bruto = String(texto || "") + " " + String(assunto || "");
    var cands = datasDaNotificacao(bruto);
    var validas = cands.filter(function(c){ return !c.bloqueada; });
    var escolhida = validas.filter(function(c){ return c.infracao; })[0] ||
      validas.slice().sort(function(a, b){ return a.iso < b.iso ? -1 : a.iso > b.iso ? 1 : (b.hora ? 1 : 0) - (a.hora ? 1 : 0); })[0];
    if (escolhida) d.data_infracao = escolhida.iso.slice(0, 10) + "T" + (escolhida.hora || "00:00") + ":00-03:00";
    var ma = t.match(/(?:AUTO DE INFRACAO|\bAIT\b)(?: N[OU]?(?:MERO)?)?( DO AUTO)? ?([A-Z]{0,3}[0-9][A-Z0-9]{4,15})/);
    if (ma) d.ait = ma[2];
    var mo = t.match(/\b(DETRAN ?[A-Z]{2}|DER ?[A-Z]{2}|DNIT|PRF|CET ?[A-Z]{0,3}|DSV|PREFEITURA (?:MUNICIPAL )?DE [A-Z ]{3,30}?)(?= |$)/);
    if (mo) d.orgao = mo[1].trim();
    var mc = t.match(/(?:CODIGO|COD)(?: DA INFRACAO| DO ENQUADRAMENTO| DE ENQUADRAMENTO)? ?([0-9]{3}) ?([0-9]{1,2})\b/);
    if (mc) d.codigo = mc[1] + "-" + mc[2];
    var mv = bruto.match(/valor[^\d]{0,40}?R?\$?\s*(\d{1,3}(?:\.\d{3})*,\d{2})/i);
    if (mv) d.valor = Number(mv[1].replace(/\./g, "").replace(",", "."));
    return d;
  }

  global.RegrasMulta = { finNorm: finNorm, ehEmailDeMulta: ehEmailDeMulta, lerNotificacaoMulta: lerNotificacaoMulta, datasDaNotificacao: datasDaNotificacao };
})(globalThis);
