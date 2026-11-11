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

  // ---------- Esteira: próximos passos (Etapa 4c, 30/10/2026) ----------
  // Espelho dos caminhos aceitos pelo gatilho frota.tg_descontos_folha_regras — o banco continua sendo a trava final.
  // Quem registra as respostas do líder e do DP é a Frota (eles não têm login); o histórico guarda quem registrou.
  // campos: motorista (cobrado, obrigatório), motorista_se_faltar (só pede se ainda não houver), motorista_novo (trocar por outro),
  //   contestacao_motivo, motivo_custo_beep, motivo_rejeicao_dp, motivo_cobranca_errada, observacao, fase_reabrir.
  // encerra = leva a uma fase final (a tela pede uma confirmação a mais).
  var DESCONTO_PASSOS = [
    { id: "concordou", de: "enviado_lider", para: "conferencia_frota", nome: "Motorista concordou", campos: ["motorista"], fixos: { motorista_concorda: "sim" } },
    { id: "contestou", de: "enviado_lider", para: "avaliacao_frota", nome: "Motorista contestou", campos: ["motorista", "contestacao_motivo"], fixos: { motorista_concorda: "nao" } },
    { id: "desligado", de: "enviado_lider", para: "analise_rh", nome: "Motorista já desligado", campos: ["motorista"], fixos: { motorista_concorda: "desligado" } },
    { id: "contestacao_invalida", de: "avaliacao_frota", para: "conferencia_frota", nome: "Contestação não válida", campos: [], fixos: { contestacao_valida: false } },
    { id: "contestacao_custo_beep", de: "avaliacao_frota", para: "custo_beep", nome: "Válida: a empresa absorve", campos: ["motivo_custo_beep"], fixos: { contestacao_valida: true }, encerra: true },
    { id: "outro_motorista", de: "avaliacao_frota", para: "enviado_lider", nome: "Válida: era outro motorista", campos: ["motorista_novo", "observacao"], fixos: { contestacao_valida: true },
      rotuloObs: "Por que era outro motorista" },
    { id: "enviar_dp", de: "conferencia_frota", para: "encaminhado_dp", nome: "Enviar ao DP", campos: ["motorista_se_faltar"], fixos: {} },
    { id: "devolver_lider", de: "conferencia_frota", para: "enviado_lider", nome: "Devolver ao líder", campos: ["observacao"], fixos: {},
      rotuloObs: "Observações da Frota (o motivo)" },
    { id: "conferencia_custo_beep", de: "conferencia_frota", para: "custo_beep", nome: "Não cobrar: Custo Beep", campos: ["motivo_custo_beep"], fixos: {}, encerra: true },
    { id: "com_retencao", de: "analise_rh", para: "encaminhado_dp", nome: "Tem retenção rescisória: enviar ao DP", campos: [], fixos: { retencao_rescisoria: true } },
    { id: "sem_retencao", de: "analise_rh", para: "custo_beep", nome: "Sem retenção: Custo Beep", campos: [], fixos: { retencao_rescisoria: false }, encerra: true },
    { id: "confirmado", de: "encaminhado_dp", para: "confirmado_dp", nome: "Confirmado pelo DP", campos: [], fixos: {}, encerra: true },
    { id: "rejeitada", de: "encaminhado_dp", para: "rejeitada_dp", nome: "Rejeitada pelo DP", campos: ["motivo_rejeicao_dp"], fixos: {} },
    { id: "reenviar_dp", de: "rejeitada_dp", para: "encaminhado_dp", nome: "Reenviar ao DP", campos: ["observacao"], fixos: {},
      rotuloObs: "O que foi corrigido" },
    { id: "rejeitada_custo_beep", de: "rejeitada_dp", para: "custo_beep", nome: "Custo Beep", campos: ["motivo_custo_beep"], fixos: {}, encerra: true },
    { id: "cobranca_errada", de: "*", para: "cobranca_errada", nome: "Cobrança errada", campos: ["motivo_cobranca_errada"], fixos: {}, encerra: true },
    { id: "reabrir", de: "final", para: null, nome: "Reabrir (admin)", campos: ["fase_reabrir", "observacao"], fixos: {}, soAdmin: true,
      rotuloObs: "Motivo da reabertura" }
  ];
  // texto obrigatório: pelo menos 5 caracteres sem contar os espaços das pontas (= frota.texto_ok)
  function textoOk(t) { return String(t == null ? "" : t).trim().length >= 5; }
  // papel: "admin", "opera" (operador com Multas) ou qualquer outro (só vê → nenhum botão)
  function proximosPassos(fase, papel) {
    var f = faseDesconto(fase);
    if (!f || (papel !== "admin" && papel !== "opera")) return [];
    return DESCONTO_PASSOS.filter(function(p){
      if (f.final) return p.de === "final" && papel === "admin";
      return p.de === fase || p.de === "*";
    });
  }
  function passoDesconto(id) {
    for (var i = 0; i < DESCONTO_PASSOS.length; i++) if (DESCONTO_PASSOS[i].id === id) return DESCONTO_PASSOS[i];
    return null;
  }
  var TEXTO_CAMPO = { contestacao_motivo: "o motivo da contestação", motivo_custo_beep: "o motivo do Custo Beep",
    motivo_rejeicao_dp: "o motivo da rejeição do DP", motivo_cobranca_errada: "o motivo da cobrança errada" };
  // dados = o que a pessoa preencheu; atual = o desconto como está ({ motorista_id }).
  // Devolve { erro } ou { patch } (o corpo do PATCH em descontos_folha).
  function montarPasso(passo, dados, atual) {
    if (typeof passo === "string") passo = passoDesconto(passo);
    if (!passo) return { erro: "Passo desconhecido." };
    dados = dados || {}; atual = atual || {};
    var patch = { fase: passo.para };
    for (var k in passo.fixos) patch[k] = passo.fixos[k];
    for (var i = 0; i < passo.campos.length; i++) {
      var c = passo.campos[i];
      if (c === "motorista") {
        if (!dados.motorista_id) return { erro: "Escolha o motorista cobrado." };
        patch.motorista_id = dados.motorista_id;
      } else if (c === "motorista_se_faltar") {
        if (!atual.motorista_id && !dados.motorista_id) return { erro: "Escolha o motorista antes de enviar ao DP." };
        if (!atual.motorista_id) patch.motorista_id = dados.motorista_id;
      } else if (c === "motorista_novo") {
        if (!dados.motorista_id) return { erro: "Escolha o motorista correto." };
        if (dados.motorista_id === atual.motorista_id) return { erro: "Escolha um motorista diferente do atual." };
        patch.motorista_id = dados.motorista_id;
      } else if (c === "fase_reabrir") {
        var f = faseDesconto(dados.fase_reabrir);
        if (!f || f.final) return { erro: "Escolha para qual fase em andamento o desconto volta." };
        patch.fase = f.chave;
      } else if (c === "observacao") {
        if (!textoOk(dados.observacao)) return { erro: "Preencha " + (passo.rotuloObs || "a observação").toLowerCase() + " (pelo menos 5 letras)." };
        patch.observacao_fase = String(dados.observacao).trim();
      } else {
        if (!textoOk(dados[c])) return { erro: "Informe " + TEXTO_CAMPO[c] + " (pelo menos 5 letras)." };
        patch[c] = String(dados[c]).trim();
      }
    }
    return { patch: patch };
  }

  // ---------- Corrigir dados sem trocar de fase (Etapa 4c) — mesma regra do gatilho no banco ----------
  // Corrigir (mudar um valor que já existia) exige justificativa; definir motorista ou líder pela 1ª vez não exige.
  // antes/depois: { motorista_id, lider_nome, valor_bruto, valor_com_desconto, parcelas } (+ antes.valor).
  // Devolve { erro } ou { patch, mudou: [rótulos], exigeJustificativa }.
  function correcaoDesconto(antes, depois, justificativa) {
    var num = function(v){ if (v == null || v === "") return null; var x = Number(v); return isNaN(x) ? NaN : Math.round(x * 100) / 100; };
    var txt = function(v){ v = String(v == null ? "" : v).trim(); return v || null; };
    var b0 = num(antes.valor_bruto), d0 = num(antes.valor_com_desconto), b1 = num(depois.valor_bruto), d1 = num(depois.valor_com_desconto);
    if (isNaN(b1) || isNaN(d1) || (b1 != null && b1 <= 0) || (d1 != null && d1 <= 0)) return { erro: "Valor inválido." };
    if (b1 == null && d1 == null) return { erro: "Informe o valor bruto." };
    if (b1 != null && d1 != null && d1 > b1) return { erro: "O valor com desconto não pode ser maior que o bruto." };
    var p1 = Number(depois.parcelas);
    if (!parcelasValidas(p1)) return { erro: "Escolha o número de parcelas (de 1 a 6)." };
    var v0 = num(antes.valor), v1 = valorConsiderado(b1, d1);
    var l0 = txt(antes.lider_nome), l1 = txt(depois.lider_nome);
    var m0 = antes.motorista_id || null, m1 = depois.motorista_id || null;
    var patch = {}, mudou = [], exige = false;
    if (m1 !== m0) { patch.motorista_id = m1; mudou.push("motorista"); if (m0) exige = true; }
    if (l1 !== l0) { patch.lider_nome = l1; mudou.push("líder"); if (l0) exige = true; }
    // desconto antigo só com "valor" (sem bruto/com desconto): a tela mostra o valor no campo do bruto
    var b0c = (b0 == null && d0 == null) ? v0 : b0;
    if (b1 !== b0c) { patch.valor_bruto = b1; if (b0c != null) exige = true; }
    if (d1 !== d0) { patch.valor_com_desconto = d1; exige = true; }
    if (v1 !== v0) exige = true;
    if (b1 !== b0c || d1 !== d0) mudou.push("valor");
    if (p1 !== Number(antes.parcelas)) { patch.parcelas = p1; mudou.push("parcelas"); exige = true; }
    if (!mudou.length) return { erro: "Nada mudou." };
    if (exige && !textoOk(justificativa)) return { erro: "Escreva a justificativa da correção (pelo menos 5 letras)." };
    if (textoOk(justificativa)) patch.observacao_fase = String(justificativa).trim();
    return { patch: patch, mudou: mudou, exigeJustificativa: exige };
  }

  // ---------- Anexos dos descontos (Etapa 4d, 30/10/2026) ----------
  // Mesmas regras do bucket descontos-anexos (10 MB; PDF ou imagem) e do gatilho frota.tg_descontos_anexos.
  // Documento pessoal (CNH, RG): só admin abre; o caminho não leva o nome original do arquivo (pode ter o nome da pessoa).
  var ANEXO_MAX_BYTES = 10 * 1024 * 1024;
  var ANEXO_MIMES = ["application/pdf", "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"];
  var ANEXO_TIPOS = [
    { chave: "termo", nome: "Termo assinado", soAdminAbre: false },
    { chave: "documento_pessoal", nome: "Documento pessoal (CNH, RG)", soAdminAbre: true },
    { chave: "outro", nome: "Outro (AIT, orçamento, comprovante)", soAdminAbre: false }
  ];
  function anexoTipo(chave) {
    for (var i = 0; i < ANEXO_TIPOS.length; i++) if (ANEXO_TIPOS[i].chave === chave) return ANEXO_TIPOS[i];
    return null;
  }
  // arquivo = { name, size, type } (o File do navegador). Devolve "" se pode enviar, ou a mensagem do problema.
  function anexoDescontoErro(arquivo, tipo) {
    if (!anexoTipo(tipo)) return "Escolha o tipo do anexo.";
    if (!arquivo) return "Escolha um arquivo.";
    if (!(arquivo.size > 0)) return "O arquivo está vazio.";
    if (arquivo.size > ANEXO_MAX_BYTES) return "Arquivo maior que 10 MB.";
    var mime = String(arquivo.type || "").toLowerCase();
    if (!mime && /\.(heic|heif)$/i.test(arquivo.name || "")) mime = "image/heic"; // alguns celulares não informam o tipo do HEIC
    if (ANEXO_MIMES.indexOf(mime) < 0) return "Só PDF ou foto (JPG, PNG, WEBP, HEIC).";
    return "";
  }
  // caminho no bucket: {desconto}/{momento}-{nome limpo} ou {desconto}/pessoal/{momento}.{extensão}
  function caminhoAnexoDesconto(descontoId, tipo, nomeArquivo, momento) {
    var nome = String(nomeArquivo || "arquivo");
    var ext = (nome.match(/\.([A-Za-z0-9]{1,5})$/) || [])[1];
    ext = ext ? ext.toLowerCase() : "";
    if (tipo === "documento_pessoal") return descontoId + "/pessoal/" + momento + (ext ? "." + ext : "");
    var limpo = nome.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-zA-Z0-9._-]/g, "_").replace(/_+/g, "_").slice(-80);
    return descontoId + "/" + momento + "-" + limpo;
  }
  function podeAbrirAnexo(tipo, papel) {
    var t = anexoTipo(tipo);
    if (!t) return false;
    if (papel === "admin") return true;
    return papel === "opera" && !t.soAdminAbre;
  }

  // ---------- Financeiro F1 (06/11/2026): leitura do Controle de Notas e dos extratos Ticket Log / Edenred ----------
  // Funções puras: recebem as linhas já lidas do arquivo (o navegador lê com SheetJS) e devolvem o que vai para o banco.
  // Dados pessoais NUNCA saem daqui: só as colunas listadas em cada leitor são lidas; nome do motorista, matrícula,
  // número do cartão, responsável e dados bancários ficam no arquivo.
  // Decisões do Jefferson (06/11/2026): Ticket Log por mês civil da transação; estorno desconta; conserto de pneu e óleo
  // = "outros"; pedágio sem placa (tag em estoque / aquisição) → MOURISCO; placa fora do cadastro (combustível) → hub da
  // "INFORMACAO ADIDIONAL 2".
  function finNorm(s) {
    return String(s == null ? "" : s).normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
  }
  var COLUNA_PESSOAL = /(NOME MOTORISTA|MOTORISTA|MATRICULA|CARTAO|RESPONSAVEL|CPF|BANCO|AGENCIA|E MAIL|EMAIL)/;
  function colunaPessoal(nome) { return COLUNA_PESSOAL.test(finNorm(nome)); }
  var HUB_APELIDOS = { "MATRIZ": "MOURISCO", "SAO BERNARDO": "SAO BERNARDO DO CAMPO", "SBC": "SAO BERNARDO DO CAMPO", "BARRA": "BARRA DA TIJUCA" };
  // texto livre ("SÃO CRISTOVÃO", "ALPHAVILLE - SP", "MATRIZ") → nome do hub cadastrado, ou null
  function hubDoTexto(texto, nomesHubs) {
    var n = finNorm(String(texto == null ? "" : texto).split(" - ")[0]);
    if (!n || n === "ND") return null;
    n = HUB_APELIDOS[n] || n;
    var porNorm = {}; (nomesHubs || []).forEach(function(h){ porNorm[finNorm(h)] = h; });
    if (porNorm[n]) return porNorm[n];
    var achados = Object.keys(porNorm).filter(function(k){ return k.indexOf(n) === 0 || n.indexOf(k) === 0; });
    return achados.length === 1 ? porNorm[achados[0]] : null;
  }
  // CONTA da planilha de notas → coluna do fechamento
  function colunaDaConta(conta) {
    var n = finNorm(conta);
    if (n.indexOf("LOCACAO") === 0) return "aluguel";
    if (n.indexOf("COMBUST") === 0) return "combustivel";
    if (n.indexOf("PEDAGIO") === 0 || n.indexOf("ESTACIONAMENTO") === 0) return "pedagio_estacionamento";
    if (n.indexOf("LAVAGEM") === 0) return "lavagem";
    if (n.indexOf("GARAGEM") === 0) return "garagem";
    return "outras";
  }
  // serviço / tipo de transação → categoria da tabela financeiro_transacoes_cartao
  function categoriaCartao(origem, subtipo) {
    var n = finNorm(subtipo);
    if (origem === "ticket_log") return n.indexOf("ABASTEC") === 0 ? "combustivel" : n.indexOf("LAVAGEM") === 0 ? "lavagem" : "outros";
    if (n.indexOf("ESTACIONAMENTO") > -1) return "estacionamento";
    if (n.indexOf("PEDAGIO") > -1) return "pedagio";
    if (n.indexOf("TAG") > -1) return "taxa_tag";
    return "outros";
  }
  function doisDig(n) { return (n < 10 ? "0" : "") + n; }
  // número de série do Excel (data/hora como aparece na planilha, horário de Brasília) → "AAAA-MM-DDTHH:MM:SS-03:00"
  function serialExcelParaISO(serial) {
    if (typeof serial !== "number" || !isFinite(serial)) return null;
    var ms = Math.round((serial - 25569) * 86400000 / 1000) * 1000, d = new Date(ms);
    return d.getUTCFullYear() + "-" + doisDig(d.getUTCMonth() + 1) + "-" + doisDig(d.getUTCDate()) + "T" +
      doisDig(d.getUTCHours()) + ":" + doisDig(d.getUTCMinutes()) + ":" + doisDig(d.getUTCSeconds()) + "-03:00";
  }
  // "09/10/2026" + "14:27:02" → "2026-10-09T14:27:02-03:00"
  function dataHoraBR(data, hora) {
    var m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(String(data || "").trim());
    if (!m) return null;
    var h = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(String(hora || "").trim()) || [null, "00", "00", "00"];
    return m[3] + "-" + m[2] + "-" + m[1] + "T" + h[1] + ":" + h[2] + ":" + (h[3] || "00") + "-03:00";
  }
  // "-1.234,56" → -1234.56 ; vazio/texto → null
  function valorBR(t) {
    var s = String(t == null ? "" : t).replace(/\s|R\$/g, "");
    if (!s) return null;
    // sem vírgula e o último ponto seguido de 1–2 dígitos no fim ("3.405.00", "1234.5"): esse ponto é o decimal
    // (digitação errada que já apareceu no Controle de Notas). "1.234" continua sendo milhar.
    if (s.indexOf(",") < 0 && /\.\d{1,2}$/.test(s)) { var k = s.lastIndexOf("."); s = s.slice(0, k).replace(/\./g, "") + "," + s.slice(k + 1); }
    var n = Number(s.replace(/\./g, "").replace(",", "."));
    return isNaN(n) ? null : Math.round(n * 100) / 100;
  }
  function numOuNull(v) { if (v == null || v === "") return null; var n = Number(v); return isNaN(n) ? null : n; }
  // 1ª, 2ª… linha com a mesma chave dentro do arquivo (o código da transação se repete de verdade)
  function marcarOcorrencias(linhas, chave) {
    var vistos = {};
    linhas.forEach(function(l){ var k = chave(l); vistos[k] = (vistos[k] || 0) + 1; l.ocorrencia = vistos[k]; });
    return linhas;
  }
  function limparPlaca(p) { return String(p == null ? "" : p).toUpperCase().replace(/[^A-Z0-9]/g, ""); }
  function indiceColunas(cab) { var ix = {}; (cab || []).forEach(function(c, i){ if (c != null && ix[finNorm(c)] == null) ix[finNorm(c)] = i; }); return ix; }
  function exigeColunas(ix, nomes, arquivo) {
    var faltam = nomes.filter(function(n){ return ix[finNorm(n)] == null; });
    if (faltam.length) throw new Error(arquivo + ": faltam as colunas " + faltam.join(", ") + ".");
  }
  // cadastro = { veiculos: { PLACA: { id, hub } }, hubs: [nomes] } (hub = nome do hub)
  function hubDaTransacao(placa, textoReserva, cadastro, semPlacaVaiPara) {
    var v = placa ? cadastro.veiculos[placa] : null;
    if (v && v.hub) return { veiculo_id: v.id, hub: v.hub, hub_regra: "cadastro" };
    if (!placa && semPlacaVaiPara) return { veiculo_id: null, hub: semPlacaVaiPara, hub_regra: "matriz_sem_placa" };
    var h = textoReserva ? hubDoTexto(textoReserva, cadastro.hubs) : null;
    if (h) return { veiculo_id: v ? v.id : null, hub: h, hub_regra: "informacao_adicional" };
    return { veiculo_id: v ? v.id : null, hub: null, hub_regra: "sem_hub" };
  }

  // Ticket Log (RFCV .xlsx): linhas = sheet_to_json(header:1, raw:true); mes = "AAAA-MM". Só as transações do mês civil.
  function lerTicketLog(linhas, mes, cadastro, arquivo) {
    var ix = indiceColunas(linhas[0]);
    exigeColunas(ix, ["CODIGO TRANSACAO", "DATA TRANSACAO", "PLACA", "SERVICO", "VALOR EMISSAO"], "Ticket Log");
    var c = function(l, nome){ var i = ix[finNorm(nome)]; return i == null ? null : l[i]; };
    var out = [];
    for (var r = 1; r < linhas.length; r++) {
      var l = linhas[r]; if (!l || c(l, "CODIGO TRANSACAO") == null) continue;
      var iso = serialExcelParaISO(c(l, "DATA TRANSACAO"));
      if (!iso || iso.slice(0, 7) !== mes) continue;
      var placa = limparPlaca(c(l, "PLACA")), sub = String(c(l, "SERVICO") || "").trim();
      var h = hubDaTransacao(placa, c(l, "INFORMACAO ADIDIONAL 2"), cadastro, null);
      out.push({
        origem: "ticket_log", transacao_id_externo: String(c(l, "CODIGO TRANSACAO")), data_hora: iso, placa: placa || null,
        veiculo_id: h.veiculo_id, hub: h.hub, hub_regra: h.hub_regra, categoria: categoriaCartao("ticket_log", sub), subtipo: sub,
        valor: Math.round((numOuNull(c(l, "VALOR EMISSAO")) || 0) * 100) / 100, litros: numOuNull(c(l, "LITROS")),
        valor_unitario: numOuNull(c(l, "VL/LITRO")), hodometro_informado: numOuNull(c(l, "HODOMETRO OU HORIMETRO")),
        tipo_combustivel: c(l, "TIPO COMBUSTIVEL") ? String(c(l, "TIPO COMBUSTIVEL")) : null,
        estabelecimento: c(l, "NOME ESTABELECIMENTO") ? String(c(l, "NOME ESTABELECIMENTO")).trim() : null,
        cidade: c(l, "CIDADE") ? String(c(l, "CIDADE")).trim() : null,
        uf: /^[A-Z]{2}$/.test(String(c(l, "UF") || "").trim()) ? String(c(l, "UF")).trim() : null,
        fatura_referencia: null, mes_competencia: mes + "-01", arquivo_origem: arquivo || null
      });
    }
    return marcarOcorrencias(out, function(t){ return [t.transacao_id_externo, t.subtipo, t.valor].join("|"); });
  }

  // Edenred (CSV ";" com vírgula decimal e cabeçalho da fatura nas primeiras linhas). A fatura inteira é uma competência.
  function campoCSV(s) { var out = [], cur = "", q = false; for (var i = 0; i < s.length; i++) { var ch = s[i]; if (ch === '"') q = !q; else if (ch === ";" && !q) { out.push(cur); cur = ""; } else cur += ch; } out.push(cur); return out; }
  var MESES_ABREV = { JAN: 1, FEV: 2, MAR: 3, ABR: 4, MAI: 5, JUN: 6, JUL: 7, AGO: 8, SET: 9, OUT: 10, NOV: 11, DEZ: 12 };
  function lerEdenred(texto, cadastro, arquivo) {
    var linhas = String(texto || "").replace(/^﻿/, "").split(/\r?\n/);
    var fatura = null, mes = null, iCab = -1;
    for (var i = 0; i < linhas.length && i < 30; i++) {
      var s = linhas[i];
      var f = /^C[oó]digo da Fatura:\s*(\d+)/i.exec(s); if (f) fatura = f[1];
      var m = /^M[eê]s de refer[eê]ncia:\s*([a-zç]{3})[a-z.]*\/(\d{4})/i.exec(s); if (m) { var mm = MESES_ABREV[finNorm(m[1])]; if (mm) mes = m[2] + "-" + doisDig(mm); }
      if (/^C[oó]digo;Data da Transa/i.test(s)) { iCab = i; break; }
    }
    if (iCab < 0) throw new Error("Edenred: cabeçalho das transações não encontrado.");
    if (!mes) throw new Error("Edenred: \"Mês de referência\" não encontrado no cabeçalho da fatura.");
    var ix = indiceColunas(campoCSV(linhas[iCab]));
    exigeColunas(ix, ["Código", "Data da Transação", "Hora da Transação", "Tipo de Transação", "Placa", "Valor cobrado(R$)"], "Edenred");
    var c = function(l, nome){ var k = ix[finNorm(nome)]; return k == null ? "" : String(l[k] == null ? "" : l[k]).trim(); };
    var out = [];
    for (var r = iCab + 1; r < linhas.length; r++) {
      if (!linhas[r].trim()) continue;
      var l = campoCSV(linhas[r]);
      var placa = limparPlaca(c(l, "Placa")), sub = c(l, "Tipo de Transação"), cobrado = valorBR(c(l, "Valor cobrado(R$)"));
      var h = hubDaTransacao(placa, null, cadastro, "MOURISCO");
      var end = c(l, "Endereço"), uf = (/ - ([A-Z]{2})$/.exec(end) || [])[1] || null;
      var cidade = uf ? (end.replace(/ - [A-Z]{2}$/, "").split(",").pop() || "").trim() || null : null;
      out.push({
        origem: "edenred", transacao_id_externo: c(l, "Código"), data_hora: dataHoraBR(c(l, "Data da Transação"), c(l, "Hora da Transação")),
        placa: placa || null, veiculo_id: h.veiculo_id, hub: h.hub, hub_regra: h.hub_regra,
        categoria: categoriaCartao("edenred", sub), subtipo: sub,
        valor: cobrado == null ? 0 : Math.round(-cobrado * 100) / 100,   // cobrança vem negativa; estorno positivo → desconta
        litros: null, valor_unitario: null, hodometro_informado: null, tipo_combustivel: null,
        estabelecimento: c(l, "Estabelecimento") || null, cidade: cidade, uf: uf,
        fatura_referencia: fatura, mes_competencia: mes + "-01", arquivo_origem: arquivo || null
      });
    }
    return { mes: mes, fatura: fatura, linhas: marcarOcorrencias(out, function(t){ return [t.transacao_id_externo, t.subtipo, t.valor].join("|"); }) };
  }

  // Controle de Notas (aba "CONTROLE DE NOTAS 2026"): só STATUS = Aprovado, da competência escolhida e com NÚMERO DO PIPE.
  // Pipe repetido na planilha: fica a última linha (e entra no aviso). A 2ª coluna "CONTA" (bancária) nunca é lida.
  function lerControleNotas(linhas, mes) {
    var cab = linhas[0] || [], ix = {};
    cab.forEach(function(c, i){ var k = finNorm(c); if (c != null && ix[k] == null) ix[k] = i; }); // 1ª "CONTA" = conta contábil
    exigeColunas(ix, ["FORNECEDOR", "HUB", "CONTA", "VALOR", "MÊS REFERÊNCIA", "ANO", "NÚMERO DO PIPE", "STATUS"], "Controle de Notas");
    var c = function(l, nome){ var i = ix[finNorm(nome)]; return i == null ? null : l[i]; };
    var ano = Number(mes.slice(0, 4)), m = Number(mes.slice(5, 7));
    var porPipe = {}, semPipeLista = [], repetidos = 0, ocorr = {};
    for (var r = 1; r < linhas.length; r++) {
      var l = linhas[r]; if (!l || !c(l, "FORNECEDOR")) continue;
      if (finNorm(c(l, "STATUS")) !== "APROVADO") continue;
      if (Number(c(l, "MÊS REFERÊNCIA")) !== m || Number(c(l, "ANO")) !== ano) continue;
      var pipe = c(l, "NÚMERO DO PIPE") == null ? "" : String(c(l, "NÚMERO DO PIPE")).trim();
      var dv = c(l, "DATA DE VENCIMENTO"), dp = c(l, "DATA DE PAGAMENTO");
      var nota = {
        pipefy_card_id: pipe, fornecedor: String(c(l, "FORNECEDOR")).trim(),
        cnpj: String(c(l, "CNPJ") || "").replace(/\D/g, "") || null,
        hub_texto: c(l, "HUB") ? String(c(l, "HUB")).trim() : null, conta: String(c(l, "CONTA") || "").trim(),
        coluna: colunaDaConta(c(l, "CONTA")), numero_nota: c(l, "NOTA FISCAL") != null ? String(c(l, "NOTA FISCAL")).trim() : null,
        valor: (function(v){ var n = typeof v === "number" ? v : valorBR(v); return Math.round((n || 0) * 100) / 100; })(c(l, "VALOR")),
        data_vencimento: typeof dv === "number" ? serialExcelParaISO(dv).slice(0, 10) : null,
        data_pagamento: typeof dp === "number" ? serialExcelParaISO(dp).slice(0, 10) : null,
        forma_pagamento: c(l, "FORMA DE PAGAMENTO") ? String(c(l, "FORMA DE PAGAMENTO")).trim() : null,
        mes_referencia: mes + "-01"
      };
      if (!/^\d+$/.test(pipe)) {
        // sem Pipe: vai para a lista de conferência com um ID temporário fixo (só entra se o usuário marcar)
        var ass = assinaturaNota(nota); ocorr[ass] = (ocorr[ass] || 0) + 1;
        nota.pipefy_card_id = null; nota.id_temporario = idTemporarioNota(nota, ocorr[ass]);
        semPipeLista.push(nota); continue;
      }
      if (porPipe[pipe]) repetidos++;
      nota.pipefy_card_id = pipe;
      porPipe[pipe] = nota;
    }
    return { notas: Object.keys(porPipe).map(function(k){ return porPipe[k]; }), semPipe: semPipeLista.length, semPipeLista: semPipeLista, pipesRepetidos: repetidos };
  }

  // ID temporário de nota sem Pipe: "TEMP-AAAAMM-xxxxxxxx", calculado de fornecedor + NF + valor (+ ocorrência, se houver
  // duas iguais). É sempre o mesmo para a mesma nota: reimportar não duplica e, quando o Pipe for preenchido na planilha,
  // a nota temporária é achada por ele e recebe o número do Pipe (ver idsTemporariosCandidatos).
  function assinaturaNota(n) {
    return [finNorm(n.fornecedor), finNorm(n.numero_nota == null || n.numero_nota === "-" ? "" : n.numero_nota), (Number(n.valor) || 0).toFixed(2)].join("|");
  }
  function hash32(s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return ("0000000" + h.toString(16)).slice(-8);
  }
  function idTemporarioNota(n, ocorrencia) {
    var mes = String(n.mes_referencia || "").slice(0, 7).replace("-", "");
    return "TEMP-" + mes + "-" + hash32(assinaturaNota(n) + "|" + (ocorrencia || 1));
  }
  // notas COM Pipe da carga → IDs temporários que elas teriam (1ª, 2ª… nota igual), para trocar o TEMP pelo Pipe
  function idsTemporariosCandidatos(notas) {
    var ocorr = {}, out = {};
    (notas || []).forEach(function(n){ var a = assinaturaNota(n); ocorr[a] = (ocorr[a] || 0) + 1; out[n.pipefy_card_id] = idTemporarioNota(n, ocorr[a]); });
    return out;
  }

  // "Fechamento Mensal - Operações" (aba "Rateio"), bloco "Motoristas": HUB + uma coluna por BU com o %.
  // A planilha não tem mês (vem da tela). Linha "Total" → hub null (vale para MOURISCO e "(sem hub)", decisão do Jefferson
  // de 11/11/2026). % pode vir como fração (0,40) ou número (40). Cada hub precisa somar 100% (tolerância 0,1 ponto).
  function lerRateioBU(linhas, mes, nomesHubs) {
    var lin = -1, col = -1;
    for (var r = 0; r < linhas.length && lin < 0; r++) {
      (linhas[r] || []).forEach(function(v, i){ if (lin < 0 && finNorm(v) === "MOTORISTAS") { lin = r; col = i; } });
    }
    // sem o título "Motoristas": layout conhecido da planilha (cabeçalho HUB em F2, dados F3:I13, Total na 14)
    if (lin < 0 && finNorm((linhas[1] || [])[5]) === "HUB") { lin = 0; col = 5; }
    if (lin < 0) throw new Error('Rateio: não achei o bloco "Motoristas" (nem o cabeçalho HUB em F2) na aba.');
    var cab = linhas[lin + 1] || [];
    if (finNorm(cab[col]) !== "HUB") throw new Error('Rateio: a linha abaixo de "Motoristas" deveria começar com "HUB".');
    var bus = [];
    for (var c = col + 1; c < cab.length && cab[c] != null && String(cab[c]).trim(); c++) {
      bus.push({ col: c, nome: String(cab[c]).replace(/\(\s*%\s*\)/g, "").replace(/%/g, "").trim() });
    }
    if (!bus.length) throw new Error("Rateio: nenhuma coluna de BU ao lado de HUB.");
    var out = [], naoEncontrados = [], somaErrada = [], vistos = {};
    for (var k = lin + 2; k < linhas.length; k++) {
      var l = linhas[k] || [], txt = l[col] == null ? "" : String(l[col]).trim();
      if (!txt) break;
      var total = finNorm(txt) === "TOTAL", hub = total ? null : hubDoTexto(txt, nomesHubs);
      if (!total && !hub) { naoEncontrados.push(txt); continue; }
      var chave = hub || "(Total)";
      if (vistos[chave]) throw new Error("Rateio: o hub " + chave + " aparece duas vezes.");
      vistos[chave] = true;
      // número da célula (fração 0,40 quando formatada como %) ou texto ("40,14%", "0,4014", "40.14")
      var comPct = false;
      var pcts = bus.map(function(b){
        var v = l[b.col]; if (typeof v === "number") return v;
        var s = String(v == null ? "" : v); if (s.indexOf("%") > -1) comPct = true;
        var n = valorBR(s.replace(/%/g, "")); return n == null || isNaN(n) ? 0 : n;
      });
      var escala = comPct || pcts.some(function(p){ return p > 1.0001; }) ? 100 : 1;
      var soma = 0;
      pcts.forEach(function(p, i){
        var pct = Math.round(p / escala * 1e6) / 1e6; soma += pct;
        out.push({ mes_competencia: mes + "-01", hub: hub, bu_nome: bus[i].nome, percentual: pct });
      });
      if (Math.abs(soma - 1) > 0.001) somaErrada.push(chave + " (" + (Math.round(soma * 10000) / 100) + "%)");
    }
    return { linhas: out, bus: bus.map(function(b){ return b.nome; }), naoEncontrados: naoEncontrados, somaErrada: somaErrada, temTotal: !!vistos["(Total)"] };
  }

  global.Regras = {
    finNorm: finNorm,
    colunaPessoal: colunaPessoal,
    hubDoTexto: hubDoTexto,
    colunaDaConta: colunaDaConta,
    categoriaCartao: categoriaCartao,
    serialExcelParaISO: serialExcelParaISO,
    dataHoraBR: dataHoraBR,
    valorBR: valorBR,
    marcarOcorrencias: marcarOcorrencias,
    lerTicketLog: lerTicketLog,
    lerEdenred: lerEdenred,
    lerControleNotas: lerControleNotas,
    lerRateioBU: lerRateioBU,
    idTemporarioNota: idTemporarioNota,
    idsTemporariosCandidatos: idsTemporariosCandidatos,
    ANEXO_MAX_BYTES: ANEXO_MAX_BYTES,
    ANEXO_TIPOS: ANEXO_TIPOS,
    anexoTipo: anexoTipo,
    anexoDescontoErro: anexoDescontoErro,
    caminhoAnexoDesconto: caminhoAnexoDesconto,
    podeAbrirAnexo: podeAbrirAnexo,
    DESCONTO_PASSOS: DESCONTO_PASSOS,
    proximosPassos: proximosPassos,
    passoDesconto: passoDesconto,
    montarPasso: montarPasso,
    correcaoDesconto: correcaoDesconto,
    textoOk: textoOk,
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
