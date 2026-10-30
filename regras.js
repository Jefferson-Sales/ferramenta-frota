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

  global.Regras = {
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
