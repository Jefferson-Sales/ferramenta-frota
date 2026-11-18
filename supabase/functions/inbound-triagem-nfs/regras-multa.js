// GERADO por ferramentas/gerar-regras-multa.js a partir de /regras.js — não editar aqui.
(function (global) {
  function finNorm(s) {
    return String(s == null ? "" : s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toUpperCase().replace(/[^A-Z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
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

  // ---------------------------------------------------------------- Triagem de orçamentos (O1)
  // Orçamento de oficina → fila de orçamentos em Manutenções. Nota fiscal, DANFE ou boleto nunca é orçamento
  // (continua no Financeiro), mesmo que fale em "orçamento" (ex. "NF referente ao orçamento 123").
  var ORC_PALAVRAS = /\b(ORCAMENTO|ORCAMENTOS|COTACAO|COTACOES|PROPOSTA|PROPOSTAS)\b/;
  var ORC_TEXTO = /(APROVAR O ORCAMENTO|APROVACAO DO ORCAMENTO|ESTIMATIVA DE PRAZO|VALIDADE DO ORCAMENTO|VALIDADE DA PROPOSTA|PROPOSTA COMERCIAL|ORCAMENTO|COTACAO)/;
  var DOC_FISCAL = /\b(DANFE|NFS ?E|NF ?E|NFS|NF|NOTA FISCAL|NOTAS FISCAIS|BOLETO|BOLETOS|FATURA|DUPLICATA|LINHA DIGITAVEL)\b/;
  var DOC_FISCAL_TEXTO = /(DANFE|DOCUMENTO AUXILIAR DA NOTA FISCAL|NOTA FISCAL DE SERVICOS? ELETRONICA|NOTA FISCAL ELETRONICA|\bNFS ?E\b|LINHA DIGITAVEL|CHAVE DE ACESSO|FICHA DE COMPENSACAO|RECIBO DO PAGADOR|RECIBO DO SACADO)/;
  function ehEmailDeOrcamento(assunto, nomesAnexos, texto) {
    var a = finNorm(assunto), t = finNorm(texto);
    var nomes = (nomesAnexos || []).map(function(n){ return finNorm(String(n || "").replace(/\.[a-z0-9]+$/i, "").replace(/[_\-.]+/g, " ")); });
    var fiscal = a.match(DOC_FISCAL) || nomes.join(" | ").match(DOC_FISCAL) || t.match(DOC_FISCAL_TEXTO);
    if (fiscal) return { orcamento: false, motivo: null, fiscal: fiscal[1].toLowerCase() };
    var m = a.match(ORC_PALAVRAS);
    if (m) return { orcamento: true, motivo: "assunto: " + m[1].toLowerCase() };
    for (var i = 0; i < nomes.length; i++) { var mn = nomes[i].match(ORC_PALAVRAS); if (mn) return { orcamento: true, motivo: "anexo: " + mn[1].toLowerCase() }; }
    var mt = t.match(ORC_TEXTO);
    if (mt) return { orcamento: true, motivo: "texto do PDF: " + mt[1].toLowerCase() };
    return { orcamento: false, motivo: null };
  }
  function semAcentoMaiusc(s) { return String(s == null ? "" : s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toUpperCase(); }
  function valorBRtexto(s) { return Number(String(s).replace(/\./g, "").replace(",", ".")); }
  // placa (assunto primeiro: a oficina escreve ali), CNPJs do texto, valor total e o trecho dos serviços; null quando não acha
  function lerOrcamento(texto, assunto) {
    var bruto = String(texto || ""), d = { placa: null, cnpjs: [], valor: null, descricao: null };
    var PL = "([A-Z]{3}) ?-?([0-9])([A-Z0-9])([0-9]{2})";
    var a = finNorm(assunto), t = finNorm(bruto);
    var mp = a.match(new RegExp("\\b" + PL + "\\b")) || t.match(new RegExp("PLACA( DO VEICULO)? " + PL)) || t.match(new RegExp("\\b" + PL + "\\b"));
    if (mp) d.placa = mp[mp.length - 4] + mp[mp.length - 3] + mp[mp.length - 2] + mp[mp.length - 1];
    var reC = /(\d{2})\.(\d{3})\.(\d{3})\/(\d{4})-(\d{2})|CNPJ[^0-9]{0,15}(\d{14})/gi, mc;
    while ((mc = reC.exec(bruto))) { var c = mc[6] || (mc[1] + mc[2] + mc[3] + mc[4] + mc[5]); if (d.cnpjs.indexOf(c) < 0) d.cnpjs.push(c); }
    var U = semAcentoMaiusc(bruto), NUM = "(\\d{1,3}(?:\\.\\d{3})*,\\d{2})";
    var forte = new RegExp("(?:TOTAL GERAL|VALOR TOTAL|TOTAL DO ORCAMENTO|TOTAL A PAGAR|TOTAL LIQUIDO|TOTAL FINAL|TOTAL DO SERVICO|TOTAL DOS SERVICOS)[^0-9]{0,30}?(?:R\\$\\s*)?" + NUM, "g");
    var mv, ultimo = null;
    while ((mv = forte.exec(U))) ultimo = valorBRtexto(mv[1]);
    if (ultimo == null) {
      var fraco = new RegExp("TOTAL[^0-9]{0,30}?(?:R\\$\\s*)?" + NUM, "g"), maior = null;
      while ((mv = fraco.exec(U))) { var v = valorBRtexto(mv[1]); if (maior == null || v > maior) maior = v; }
      ultimo = maior;
    }
    if (ultimo == null) {
      var todos = U.match(new RegExp("R\\$\\s*" + NUM, "g")) || [];
      if (todos.length === 1) ultimo = valorBRtexto(todos[0].replace(/R\$\s*/, ""));
    }
    d.valor = ultimo != null && ultimo > 0 ? ultimo : null;
    var ini = U.search(/DESCRICAO/);
    if (ini < 0) ini = U.search(/SERVICOS? (A EXECUTAR|A SEREM EXECUTADOS|EXECUTADOS?|SOLICITADOS?)|MAO DE OBRA/);
    if (ini >= 0) {
      var fim = U.slice(ini).search(/\bSUBTOTAL|\bTOTAL/);
      var trecho = bruto.slice(ini, fim > 0 ? ini + fim : ini + 600).replace(/\s+/g, " ").trim();
      if (trecho.length >= 5) d.descricao = trecho.slice(0, 500);
    }
    return d;
  }
  // E-mail com vários PDFs de orçamento: se os PDFs têm placas diferentes, cada um vira um item (a oficina manda o
  // orçamento de vários carros no mesmo e-mail). Cada PDF é lido pelo próprio texto; o assunto só completa a placa
  // que faltar. Senão, um item só, lido pelo 1º PDF + assunto.
  function separarOrcamentos(textos, assunto) {
    var lidos = (textos || []).map(function(t){ return lerOrcamento(t, ""); });
    var placas = {};
    lidos.forEach(function(c){ if (c.placa) placas[c.placa] = 1; });
    if (lidos.length > 1 && Object.keys(placas).length > 1) {
      return lidos.map(function(c, i){ return { pdfs: [i], campos: c.placa ? c : lerOrcamento(textos[i], assunto) }; });
    }
    return [{ pdfs: (textos || []).map(function(_, i){ return i; }), campos: lerOrcamento((textos || [])[0] || "", assunto) }];
  }
  // "Mover para…": as três filas de triagem; só item pendente sai, e só para outra fila
  var FILAS_TRIAGEM = {
    financeiro: { nome: "Triagem financeira", modulo: "financeiro" },
    orcamentos: { nome: "Triagem de orçamentos (Manutenções)", modulo: "manutencao" },
    multas: { nome: "Triagem de multas", modulo: "multas" }
  };
  function destinosTriagem(de, status) {
    if (!FILAS_TRIAGEM[de] || status !== "pendente") return [];
    return Object.keys(FILAS_TRIAGEM).filter(function(k){ return k !== de; }).map(function(k){ return { fila: k, nome: FILAS_TRIAGEM[k].nome }; });
  }

  global.RegrasMulta = { finNorm: finNorm, ehEmailDeMulta: ehEmailDeMulta, lerNotificacaoMulta: lerNotificacaoMulta, datasDaNotificacao: datasDaNotificacao,
    ehEmailDeOrcamento: ehEmailDeOrcamento, lerOrcamento: lerOrcamento, separarOrcamentos: separarOrcamentos, FILAS_TRIAGEM: FILAS_TRIAGEM };
})(globalThis);
