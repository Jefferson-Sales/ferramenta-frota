// Regras de cálculo do front-end, compartilhadas pelo index.html e pelo checklist.html.
// Só funções puras (sem tela, sem banco), para poderem ser testadas em testes/regras.test.html.
// Regras que ficam no banco (km excedente, status do contrato, resultado do checklist)
// são testadas em testes/regras.test.sql.
(function (global) {
  "use strict";

  var OS_FECHADAS = ["concluida", "cancelada"];
  var PONTOS_POR_GRAU = { leve: 3, media: 4, grave: 5, gravissima: 7 };

  // Qualidade da Frota: status do veículo = pior anomalia aberta agora.
  // crítica → urgente; alta → reparo; média/baixa → atencao; nenhuma → ok; nunca teve checklist → sem.
  function statusQualidade(criticas, altas, total, temChecklist) {
    if (criticas > 0) return "urgente";
    if (altas > 0) return "reparo";
    if (total > 0) return "atencao";
    return temChecklist ? "ok" : "sem";
  }

  // Franquia de km (contrato pool): cor da faixa pelo % utilizado.
  // < 85% verde; de 85% até menos de 100% amarelo; 100% ou mais vermelho; sem dado neutro.
  function faixaFranquia(pct) {
    if (pct == null) return "neutral";
    if (pct >= 100) return "crit";
    if (pct >= 85) return "warn";
    return "good";
  }

  // OS vencida: tem previsão de retorno no passado e ainda está aberta.
  // OS só "agendada" (carro ainda não parou) e OS concluída/cancelada não contam.
  function osVencida(os, agora) {
    return !!(os.previsao_retorno && os.status !== "agendada" && OS_FECHADAS.indexOf(os.status) === -1 &&
              new Date(os.previsao_retorno) < agora);
  }

  // Checklist: km informado menor que o maior km conhecido (último checklist ou cadastro).
  // Devolve o km de referência quando deve avisar, ou 0 quando está tudo certo / não dá para comparar.
  function kmAbaixoDoUltimo(kmInformado, kmUltimoChecklist, kmCadastro) {
    var km = Number(kmInformado);
    if (!(km > 0)) return 0;
    var ref = Math.max(Number(kmUltimoChecklist) || 0, Number(kmCadastro) || 0);
    return ref && km < ref ? ref : 0;
  }

  // Revisão preventiva por km (mesma regra da função frota.situacao_revisao no banco):
  // próximo marco = último marco feito + 10.000 (sem histórico: 10.000).
  // vencida quando o km chega no marco; vencendo a partir de 1.000 km antes; modelo sem plano de itens → "sem_plano".
  function proximoMarco(ultimoMarco) {
    return (Number(ultimoMarco) || 0) + 10000;
  }
  function situacaoRevisao(km, proximo, temPlano) {
    if (!temPlano) return "sem_plano";
    km = Number(km) || 0;
    if (km >= proximo) return "vencida";
    if (km >= proximo - 1000) return "vencendo";
    return "em_dia";
  }

  // Visão Executiva (Diretoria): Admin ativo, ou Visualizador ativo com a permissão "executivo".
  // Operador nunca (decisão do Jefferson, 23/10/2026: tela só de consulta da Diretoria).
  // A mesma trava existe na Edge Function `usuarios` (não deixa gravar "executivo" para operador).
  function podeVerExecutivo(perfil) {
    if (!perfil || perfil.ativo === false) return false;
    if (perfil.papel === "admin") return true;
    return perfil.papel === "visualizador" && (perfil.modulos_visualizacao || []).indexOf("executivo") > -1;
  }

  // Status de liberação da OS (decisão do Jefferson, 23/10/2026). Mesmos valores da
  // constraint os_status_liberacao_valido no banco; OS concluída vira "liberado" (gatilho).
  var STATUS_LIBERACAO = {
    aguardando_orcamento: "Aguardando orçamento/aprovação",
    em_reparo: "Em reparo",
    pronto_retirada: "Pronto, aguardando retirada",
    liberado: "Liberado"
  };

  // Tempo em texto curto, para "há quanto tempo está neste status".
  // < 1 min → "menos de 1 min"; < 1 h → "40 min"; < 1 dia → "5 h" ou "5 h 20 min"; a partir de 1 dia → "2 d" ou "2 d 3 h".
  // Vazio, inválido ou negativo → "—".
  function duracaoTexto(ms) {
    ms = Number(ms);
    if (ms === null || isNaN(ms) || ms < 0) return "—";
    var min = Math.floor(ms / 60000);
    if (min < 1) return "menos de 1 min";
    if (min < 60) return min + " min";
    var h = Math.floor(min / 60), m = min % 60;
    if (h < 24) return h + " h" + (m ? " " + m + " min" : "");
    var d = Math.floor(h / 24), hr = h % 24;
    return d + " d" + (hr ? " " + hr + " h" : "");
  }

  // Disponibilidade da frota (Dash de Manutenção e Visão Executiva): cor pela % disponível.
  // ≥ 90% verde; ≥ 80% amarelo; abaixo vermelho; sem dado neutro.
  function faixaDisponibilidade(pct) {
    if (pct == null || isNaN(pct)) return "neutral";
    if (pct >= 90) return "good";
    if (pct >= 80) return "warn";
    return "crit";
  }

  // Visão Executiva: datas do filtro de período (texto "AAAA-MM-DD"; hoje = data local de Brasília).
  // mes = do dia 1 até hoje; mes_anterior = o mês anterior inteiro; ano = de 1º de janeiro até hoje.
  function periodoDatas(codigo, hoje) {
    var a = Number(hoje.slice(0, 4)), m = Number(hoje.slice(5, 7));
    var dois = function(n){ return (n < 10 ? "0" : "") + n; };
    if (codigo === "mes_anterior") {
      var am = m === 1 ? 12 : m - 1, aa = m === 1 ? a - 1 : a;
      var ultimo = new Date(Date.UTC(aa, am, 0)).getUTCDate();
      return { ini: aa + "-" + dois(am) + "-01", fim: aa + "-" + dois(am) + "-" + dois(ultimo) };
    }
    if (codigo === "ano") return { ini: a + "-01-01", fim: hoje };
    return { ini: a + "-" + dois(m) + "-01", fim: hoje };
  }

  // Custo por km dos elétricos só é confiável se km e recargas cobrem o mesmo período:
  // a telemetria tem que existir desde o início do período, e a última recarga lançada não
  // pode estar mais de 7 dias antes do fim do período (recarga é lançada à mão).
  // Devolve a lista de motivos (vazia = confiável). Datas em "AAAA-MM-DD".
  function coberturaCustoKm(ini, fim, telemetriaDesde, ultimaRecarga) {
    var motivos = [];
    if (!telemetriaDesde) motivos.push("sem telemetria de km");
    else if (telemetriaDesde > ini) motivos.push("telemetria de km só desde " + telemetriaDesde.split("-").reverse().join("/"));
    if (!ultimaRecarga) motivos.push("nenhuma recarga lançada");
    else {
      var limite = new Date(Date.UTC(Number(fim.slice(0, 4)), Number(fim.slice(5, 7)) - 1, Number(fim.slice(8, 10)) - 7)).toISOString().slice(0, 10);
      if (ultimaRecarga < limite) motivos.push("recargas lançadas só até " + ultimaRecarga.split("-").reverse().join("/"));
    }
    return motivos;
  }

  // ---------- Financeiro (Visão Executiva) — decisões do Jefferson, 23/10/2026 ----------
  // Mês = competência (mes_referencia da nota), em texto "AAAA-MM".
  // Um mês está FECHADO a partir do dia 05 do mês seguinte (tempo para as notas atrasadas).
  function somaMeses(mes, n) {
    var t = Number(mes.slice(0, 4)) * 12 + Number(mes.slice(5, 7)) - 1 + n;
    var m = t % 12 + 1;
    return Math.floor(t / 12) + "-" + (m < 10 ? "0" : "") + m;
  }
  function mesFechado(mes, hoje) {
    return hoje >= somaMeses(mes, 1) + "-05";
  }
  function ultimoMesFechado(hoje) {
    return somaMeses(hoje.slice(0, 7), Number(hoje.slice(8, 10)) >= 5 ? -1 : -2);
  }
  // valores = { "AAAA-MM": total do mês }. Devolve:
  //   ultimoFechado, media3 (média dos 3 últimos meses fechados), mesAtual + lancadoAtual + pctMediaAtual,
  //   realizadoAno (só meses fechados do ano corrente), mesesFechadosAno, mesesRestantes (12 − fechados),
  //   projecao = realizadoAno + media3 × mesesRestantes.
  function resumoFinanceiro(valores, hoje) {
    var v = function(m){ return Number(valores[m]) || 0; };
    var ult = ultimoMesFechado(hoje), ano = hoje.slice(0, 4), atual = hoje.slice(0, 7);
    var media3 = (v(ult) + v(somaMeses(ult, -1)) + v(somaMeses(ult, -2))) / 3;
    var realizado = 0, fechados = 0;
    if (ult.slice(0, 4) === ano) {
      for (var m = ano + "-01"; m <= ult; m = somaMeses(m, 1)) { realizado += v(m); fechados++; }
    }
    var restantes = 12 - fechados;
    return {
      ultimoFechado: ult, media3: media3, mesAtual: atual, lancadoAtual: v(atual),
      pctMediaAtual: media3 ? Math.round(v(atual) / media3 * 100) : null,
      realizadoAno: realizado, mesesFechadosAno: fechados, mesesRestantes: restantes,
      projecao: realizado + media3 * restantes
    };
  }

  // ---------- Multas: motivo agrupado ----------
  // O motivo vem do começo da descrição ("MOTIVO | Status original planilha: …"), escrito de
  // vários jeitos (com/sem acento, com sufixos). Agrupa em categorias legíveis; a ordem dos testes
  // importa (ex.: "mais de 20%" antes de "até 20%"). Sem motivo → "Sem motivo informado".
  var MOTIVOS = [
    ["Velocidade acima de 50%",            /VELOCIDADE.*(MAIS DE 50|SUPERIOR A 50)/],
    ["Velocidade de 20% a 50%",            /VELOCIDADE.*MAIS DE 20/],
    ["Velocidade até 20%",                 /VELOCIDADE/],
    ["Sinal vermelho",                     /SINAL VERMELHO|SEMAFORO/],
    ["Faixa exclusiva",                    /FAIXA OU VIA EXCLUSIVA|TRANSP(ORTE)? PUBL|CIRCULACAO EXCLUSIVA/],
    ["Estacionamento irregular",           /ESTACION|PARAR /],
    ["Fora da faixa",                      /CONSERVAR O VEICULO NA FAIXA/],
    ["Marcha à ré",                        /MARCHA (A )?RE( |,|$)/],
    ["Contramão",                          /CONTRAMAO/],
    ["Conversão ou retorno proibido",      /CONVERS|RETORNO/],
    ["Rodízio / horário não permitido",    /RODIZIO|HORARIO NAO PERMITIDO|LOCAL E HORARIO PROIBIDO|HORARIO DE PICO/],
    ["Celular ao volante",                 /CELULAR|TELEFONE/],
    ["Evasão de pedágio",                  /EVADIR|PEDAGIO/],
    ["Cinto de segurança",                 /CINTO/],
    ["Não identificação do condutor",      /NAO IDENTIFICACAO DO CONDUTOR/]
  ];
  function motivoDaDescricao(descricao) {
    var d = String(descricao || "");
    // sem " | ", ou começando pelo status ou pelo nome do motorista ("Motorista (planilha): …") = sem motivo.
    // O nome do motorista nunca vira "motivo" (mesma regra em frota.exec_multas).
    if (d.indexOf(" | ") === -1) return "";
    var p = d.split(" | ")[0].trim();
    return /^(status original|motorista \(planilha\))/i.test(p) ? "" : p;
  }
  function classificarMotivo(texto) {
    var t = String(texto || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/\s+/g, " ").trim(); // tira os acentos
    if (!t) return "Sem motivo informado";
    for (var i = 0; i < MOTIVOS.length; i++) if (MOTIVOS[i][1].test(t)) return MOTIVOS[i][0];
    return "Outros";
  }

  // ---------- Descontos em folha (multas e avarias) — decisões do Jefferson, 27/10/2026 ----------
  // Sugestão de parcelas; o operador pode ajustar de 1 até PARCELAS_MAX.
  //   multa, pela gravidade: leve 1x; média até 3x; grave/gravíssima até 6x.
  //   avaria, pelo valor: até R$ 300,00 → 1x; acima de R$ 300,00 até R$ 600,00 → 3x; acima de R$ 600,00 → 6x.
  // Sem gravidade (multa) ou sem valor (avaria) → null (sem sugestão; o operador escolhe).
  var PARCELAS_MAX = 6;
  var PARCELAS_POR_GRAU = { leve: 1, media: 3, grave: 6, gravissima: 6 };
  function parcelasSugeridas(tipo, grau, valor) {
    if (tipo === "multa") return PARCELAS_POR_GRAU[grau] || null;
    if (tipo === "avaria") {
      if (valor == null || valor === "" || isNaN(Number(valor)) || Number(valor) <= 0) return null;
      var centavos = Math.round(Number(valor) * 100);
      return centavos <= 30000 ? 1 : centavos <= 60000 ? 3 : 6;
    }
    return null;
  }
  // Valor considerado (decisão do Jefferson, 29/10/2026): o "com desconto" quando preenchido; senão, o bruto.
  // Mesma regra do banco (gatilho descontos_folha_a_valor). Vazio, zero ou texto inválido conta como não preenchido.
  function valorConsiderado(bruto, comDesconto) {
    var n = function(v){ if (v == null || v === "") return null; var x = Number(v); return isNaN(x) || x <= 0 ? null : Math.round(x * 100) / 100; };
    var d = n(comDesconto), b = n(bruto);
    return d != null ? d : b;
  }
  function parcelasValidas(n) {
    return Number.isInteger(n) && n >= 1 && n <= PARCELAS_MAX;
  }

  // Fases da esteira (mesmos nomes do banco, frota.fase_desconto) e o destino do valor de cada uma.
  // Destino (decisão do Jefferson, 27/10/2026): Confirmado pelo DP = cobrança do motorista; Custo Beep = a empresa paga;
  // Cobrança errada = sem custo para ninguém; as demais ainda estão em andamento. "Rejeitada pelo DP" não é final.
  var DESCONTO_FASES = [
    { chave: "enviado_lider",     nome: "Enviado ao líder",       final: false },
    { chave: "avaliacao_frota",   nome: "Avaliação da Frota",     final: false },
    { chave: "conferencia_frota", nome: "Conferência da Frota",   final: false },
    { chave: "analise_rh",        nome: "Análise RH",             final: false },
    { chave: "encaminhado_dp",    nome: "Encaminhado ao DP",      final: false },
    { chave: "rejeitada_dp",      nome: "Rejeitada pelo DP",      final: false },
    { chave: "confirmado_dp",     nome: "Confirmado pelo DP",     final: true },
    { chave: "custo_beep",        nome: "Custo Beep",             final: true },
    { chave: "cobranca_errada",   nome: "Cobrança errada",        final: true }
  ];
  function faseDesconto(chave) {
    for (var i = 0; i < DESCONTO_FASES.length; i++) if (DESCONTO_FASES[i].chave === chave) return DESCONTO_FASES[i];
    return null;
  }
  function destinoContabil(fase) {
    if (fase === "confirmado_dp")   return { chave: "repasse_motorista", nome: "Cobrança do motorista", tom: "good" };
    if (fase === "custo_beep")      return { chave: "custo_beep",        nome: "Custo Beep (empresa)",  tom: "crit" };
    if (fase === "cobranca_errada") return { chave: "sem_custo",         nome: "Sem custo",             tom: "neutral" };
    return { chave: "em_andamento", nome: "Em andamento", tom: "warn" };
  }

  global.Regras = {
    PARCELAS_MAX: PARCELAS_MAX,
    DESCONTO_FASES: DESCONTO_FASES,
    faseDesconto: faseDesconto,
    destinoContabil: destinoContabil,
    parcelasSugeridas: parcelasSugeridas,
    parcelasValidas: parcelasValidas,
    valorConsiderado: valorConsiderado,
    motivoDaDescricao: motivoDaDescricao,
    classificarMotivo: classificarMotivo,
    MOTIVOS_MULTA: MOTIVOS.map(function(m){ return m[0]; }).concat(["Outros", "Sem motivo informado"]),
    somaMeses: somaMeses,
    mesFechado: mesFechado,
    ultimoMesFechado: ultimoMesFechado,
    resumoFinanceiro: resumoFinanceiro,
    periodoDatas: periodoDatas,
    coberturaCustoKm: coberturaCustoKm,
    faixaDisponibilidade: faixaDisponibilidade,
    STATUS_LIBERACAO: STATUS_LIBERACAO,
    duracaoTexto: duracaoTexto,
    podeVerExecutivo: podeVerExecutivo,
    OS_FECHADAS: OS_FECHADAS,
    PONTOS_POR_GRAU: PONTOS_POR_GRAU,
    statusQualidade: statusQualidade,
    faixaFranquia: faixaFranquia,
    osVencida: osVencida,
    kmAbaixoDoUltimo: kmAbaixoDoUltimo,
    proximoMarco: proximoMarco,
    situacaoRevisao: situacaoRevisao
  };
})(typeof window !== "undefined" ? window : globalThis);
