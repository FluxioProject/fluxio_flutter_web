%% Identificação de processo e sintonia PID (curva de reação)
% Gerado pelo painel Fluxio para o dispositivo {{DISPOSITIVO}} em {{GERADO_EM}}.
% Leia o LEIA-ME.txt antes de levar qualquer ganho para o equipamento.
%
% Fluxo: carrega dados.csv -> detecta o degrau na entrada -> ajusta um
% modelo de 1a ordem com atraso (FOPDT) -> calcula ganhos por várias
% regras de sintonia -> simula a malha fechada com saturação (e TPO).
%
% Roda no MATLAB sem toolboxes e no GNU Octave.

clear; clc; close all;

%% Parâmetros (preenchidos pelo painel; ajuste se precisar)
ARQUIVO     = 'dados.csv';
COL_TEMPO   = 1;               % coluna do tempo (s)
COL_U       = {{COL_U}};       % coluna da entrada (atuador)
COL_Y       = {{COL_Y}};       % coluna da saída (variável de processo)
NOME_U      = '{{NOME_U}}';
NOME_Y      = '{{NOME_Y}}';
UNIDADE_Y   = '{{UNIDADE_Y}}';

% Escala do atuador como aparece no CSV: U_MIN = 0 %, U_MAX = 100 %.
U_MIN       = {{U_MIN}};
U_MAX       = {{U_MAX}};

% Saída do bloco PID que corresponde a 0 % e 100 % do atuador.
% PID -> TPO -> DO: o PID entrega duty, então 0 e 100.
% PID -> AO: o PID escreve direto na saída, então U_MIN e U_MAX.
PID_0       = {{PID_0}};
PID_100     = {{PID_100}};

% Saturação configurada no bloco PID (mesmas unidades da saída do PID).
PID_OUT_MIN = {{PID_OUT_MIN}};
PID_OUT_MAX = {{PID_OUT_MAX}};

% Período do TPO em segundos. [] simula a saída contínua (sem TPO).
TPO_PERIODO = {{TPO_PERIODO}};

% Constante de tempo desejada em malha fechada (regras SIMC e IMC), em s.
% [] = automático: max(L, Tau/5). Maior = mais lento e mais robusto.
TAU_C       = [];

% Setpoint usado na simulação. [] = repouso + 70 % da variação máxima possível.
SETPOINT    = [];

%% Leitura dos dados
pasta = fileparts(mfilename('fullpath'));
if isempty(pasta)
    pasta = pwd;
end
arquivo = fullfile(pasta, ARQUIVO);
if exist(arquivo, 'file') ~= 2
    error('Não encontrei %s. Deixe o CSV na mesma pasta do script.', arquivo);
end

M = dlmread(arquivo, ',', 1, 0); % pula a linha de cabeçalho
M = M(all(isfinite(M(:, [COL_TEMPO COL_U COL_Y])), 2), :);
if size(M, 1) < 30
    error('Poucos pontos válidos no CSV (%d) para identificar a curva.', size(M, 1));
end

t = M(:, COL_TEMPO) - M(1, COL_TEMPO);
uBruto = M(:, COL_U);
yBruto = M(:, COL_Y);
if U_MAX == U_MIN
    error('U_MIN e U_MAX não podem ser iguais.');
end
un = (uBruto - U_MIN)/(U_MAX - U_MIN); % entrada normalizada 0..1
Ts = median(diff(t));

% Mediana móvel rejeita picos isolados; média móvel suaviza ruído de ADC.
y = movmean(movmedian(yBruto, 5), 5);

%% Detecção do degrau
du = diff(un);
[saltoMax, kSalto] = max(abs(du));
temBorda = saltoMax >= 0.1;
if temBorda
    kDegrau = kSalto + 1;
else
    kDegrau = 1;
    warning(['Nenhum degrau encontrado em %s. Assumindo que a entrada ' ...
        'saiu de 0 %% no primeiro ponto do CSV; confirme isso no ensaio.'], NOME_U);
end

% O trecho útil termina na próxima mudança relevante da entrada.
uDegrau = un(kDegrau);
kMudanca = find(abs(un(kDegrau:end) - uDegrau) >= 0.1, 1);
if isempty(kMudanca)
    kFim = numel(t);
else
    kFim = kDegrau + kMudanca - 2;
    warning(['A entrada mudou de novo em t = %.1f s; só o trecho até ali ' ...
        'foi usado. Se havia TPO/PID ativo, refaça o ensaio com um ' ...
        'degrau manual.'], t(kFim + 1));
end
if kFim - kDegrau < 20
    error('O trecho após o degrau tem poucos pontos (%d).', kFim - kDegrau + 1);
end

if temBorda
    iBase = max(1, kDegrau - 10):(kDegrau - 1);
    u0 = median(un(iBase));
else
    iBase = 1:min(5, kFim);
    u0 = 0;
end
Y0 = mean(y(iBase));
u1 = median(un(kDegrau:kFim));
deltaU = u1 - u0;
if abs(deltaU) < 0.05
    error('O degrau na entrada é pequeno demais (%.1f %%).', 100*deltaU);
end

tt = t(kDegrau:kFim) - t(kDegrau); % tempo desde o degrau
yy = y(kDegrau:kFim);
nFinal = max(3, min(20, floor(numel(yy)/10)));
Yf = mean(yy(end - nFinal + 1:end));
deltaY = Yf - Y0;
if abs(deltaY) < eps
    error('A saída não mudou depois do degrau. Confira as colunas do CSV.');
end
K = deltaY/deltaU; % ganho estático (unidade de Y por 0..1 da entrada)

% Resposta normalizada 0..1, vale para aquecimento e resfriamento.
r = (yy - Y0)/deltaY;

%% Modelo FOPDT: método da tangente (Ziegler-Nichols)
drdt = gradient(r)./gradient(tt);
janela = max(5, 2*floor(10/Ts/2) + 1); % cerca de 10 s, ímpar
drdtSuave = movmean(drdt, janela);
faixa = (1:numel(tt))' < numel(tt) - nFinal;
drdtSuave(~faixa) = -Inf;
[incl, kInf] = max(drdtSuave);
if ~isfinite(incl) || incl <= 0
    error('Não encontrei inclinação positiva na resposta.');
end
L_tg = tt(kInf) - r(kInf)/incl;
Tau_tg = 1/incl;

%% Modelo FOPDT: dois pontos (Smith, 28,3 % e 63,2 %)
niveis = [0.283 0.632];
tNivel = nan(1, 2);
for i = 1:2
    k = find(r >= niveis(i), 1);
    if ~isempty(k) && k > 1
        tNivel(i) = tt(k - 1) + (niveis(i) - r(k - 1)) * ...
            (tt(k) - tt(k - 1))/(r(k) - r(k - 1));
    elseif ~isempty(k)
        tNivel(i) = tt(k);
    end
end
Tau_sm = 1.5*(tNivel(2) - tNivel(1));
L_sm = tNivel(2) - Tau_sm;

%% Escolhe o modelo que melhor reproduz o ensaio
respostaFOPDT = @(L, Tau) (tt > L).*(1 - exp(-(tt - L)/Tau));
modelos = {'Tangente (ZN)', L_tg, Tau_tg; 'Dois pontos (Smith)', L_sm, Tau_sm};
erros = inf(1, 2);
for i = 1:2
    Lm = max(modelos{i, 2}, 0);
    Taum = modelos{i, 3};
    if isfinite(Lm) && isfinite(Taum) && Taum > 0
        erros(i) = sqrt(mean((respostaFOPDT(Lm, Taum) - r).^2));
    end
end
[erroMin, iModelo] = min(erros);
if ~isfinite(erroMin)
    error('Nenhum modelo FOPDT válido. O degrau pode não estar registrado.');
end
L = modelos{iModelo, 2};
Tau = modelos{iModelo, 3};
if L < Ts
    warning(['Atraso estimado (%.2f s) menor que a amostragem (%.2f s); ' ...
        'usando L = Ts. Regras tipo ZN ficam muito agressivas assim.'], L, Ts);
    L = Ts;
end

% Se a inclinação final ainda moveria a saída mais de 5 % em um Tau, o
% ensaio terminou antes de estabilizar.
iFim = (numel(tt) - nFinal + 1):numel(tt);
coefFim = polyfit(tt(iFim), r(iFim), 1);
if coefFim(1)*Tau > 0.05
    warning(['A saída ainda não tinha estabilizado no fim do ensaio: K e Tau ' ...
        'tendem a sair subestimados. Registre por pelo menos 5*Tau (~%.0f s).'], 5*Tau);
end

fprintf('\n=== Identificação: %s -> %s ===\n', NOME_U, NOME_Y);
fprintf('Pontos usados: %d | Ts mediano: %.3f s\n', numel(tt), Ts);
if temBorda
    fprintf('Degrau em t = %.1f s: entrada %.1f %% -> %.1f %%\n', ...
        t(kDegrau), 100*u0, 100*u1);
else
    fprintf('Degrau assumido no primeiro ponto: entrada 0 %% -> %.1f %%\n', 100*u1);
end
fprintf('%s inicial: %.2f %s | final: %.2f %s\n', NOME_Y, Y0, UNIDADE_Y, Yf, UNIDADE_Y);
for i = 1:2
    fprintf('Modelo %-20s L = %8.3f s | Tau = %9.3f s | erro RMS = %.3f\n', ...
        modelos{i, 1}, modelos{i, 2}, modelos{i, 3}, erros(i));
end
fprintf('Usando: %s | K = %.6g %s/(entrada 0..1)\n', modelos{iModelo, 1}, K, UNIDADE_Y);

%% Regras de sintonia (PID paralelo: Kp*e + Ki*int(e) + Kd*de/dt)
if isempty(TAU_C)
    tauC = max(L, Tau/5);
else
    tauC = TAU_C;
end
% Cada linha: nome, Kc (normalizado), Ti (s), Td (s).
regras = {
    'ZN PID',         1.2*Tau/(K*L),                     2*L,                           0.5*L
    'ZN PI',          0.9*Tau/(K*L),                     L/0.3,                         0
    'Cohen-Coon PID', (Tau/(K*L))*(4/3 + L/(4*Tau)),     L*(32 + 6*L/Tau)/(13 + 8*L/Tau), 4*L/(11 + 2*L/Tau)
    'SIMC PI',        Tau/(K*(tauC + L)),                min(Tau, 4*(tauC + L)),        0
    'IMC PID',        (Tau + L/2)/(K*(tauC + L/2)),      Tau + L/2,                     Tau*L/(2*Tau + L)
};
nRegras = size(regras, 1);

% Converte para as unidades do bloco PID (saída de PID_0 a PID_100).
escala = PID_100 - PID_0;
Kp = zeros(nRegras, 1); Ki = Kp; Kd = Kp;
for i = 1:nRegras
    Kp(i) = regras{i, 2}*escala;
    Ki(i) = Kp(i)/regras{i, 3};
    Kd(i) = Kp(i)*regras{i, 4};
end

%% Simulação da malha fechada com saturação, anti-windup e TPO opcional
satMin = min(max((PID_OUT_MIN - PID_0)/escala, 0), 1);
satMax = min(max((PID_OUT_MAX - PID_0)/escala, 0), 1);
% A simulação parte do repouso (atuador em 0); pelo modelo linear, a saída
% em repouso é Y0 - K*u0.
yRepouso = Y0 - K*u0;
if isempty(SETPOINT)
    sp = yRepouso + 0.7*K*satMax;
else
    sp = SETPOINT;
end
usarTPO = ~isempty(TPO_PERIODO) && TPO_PERIODO > 0;
dt = Ts;
if usarTPO
    dt = min(Ts, TPO_PERIODO/50);
end
tFim = max(tt(end), 4*Tau + L);
tSim = (0:dt:tFim)';
nSim = numel(tSim);
nAtraso = max(0, round(L/dt));

ySim = zeros(nSim, nRegras);
uSim = zeros(nSim, nRegras);
for i = 1:nRegras
    kpN = regras{i, 2};
    kiN = kpN/regras{i, 3};
    kdN = kpN*regras{i, 4};
    x = 0;                         % desvio de Y em relação ao repouso
    filaU = zeros(nAtraso + 1, 1); % entrada atrasada pelo tempo morto
    integ = 0;
    eAnt = sp - yRepouso;
    duty = 0;
    inicioCiclo = 0;
    for k = 1:nSim
        yk = yRepouso + x;
        e = sp - yk;
        deriv = kdN*(e - eAnt)/dt;
        eAnt = e;
        saida = kpN*e + integ + deriv;
        saidaSat = min(max(saida, satMin), satMax);
        % Integração condicional: não integra se empurrar mais a saturação.
        if saida == saidaSat || sign(e) ~= sign(saida - saidaSat)
            integ = integ + kiN*e*dt;
        end
        if usarTPO
            if k == 1 || tSim(k) - inicioCiclo >= TPO_PERIODO
                inicioCiclo = tSim(k);
                duty = saidaSat;
            end
            uAplicada = double(tSim(k) - inicioCiclo < duty*TPO_PERIODO);
        else
            uAplicada = saidaSat;
        end
        filaU = [filaU(2:end); uAplicada];
        x = x + dt*(K*filaU(1) - x)/Tau;
        ySim(k, i) = yk;
        uSim(k, i) = saidaSat; % saída do PID (duty, no caso do TPO)
    end
end

fprintf('\nTau_c (SIMC/IMC) = %.2f s | setpoint simulado = %.2f %s', tauC, sp, UNIDADE_Y);
if usarTPO
    fprintf(' | TPO %.1f s\n', TPO_PERIODO);
else
    fprintf(' | saída contínua\n');
end
fprintf('Ganhos para o bloco PID (saída %g..%g):\n', PID_0, PID_100);
fprintf('%-16s %12s %12s %12s %10s %12s\n', 'Regra', 'Kp', 'Ki', 'Kd', 'Pico', 'Overshoot');
for i = 1:nRegras
    pico = max(ySim(:, i)*sign(K))*sign(K);
    overshoot = 100*(pico - sp)/(sp - yRepouso);
    fprintf('%-16s %12.6g %12.6g %12.6g %10.2f %11.1f%%\n', ...
        regras{i, 1}, Kp(i), Ki(i), Kd(i), pico, max(overshoot, 0));
end
fprintf(['\nAtenção: os ganhos são só ponto de partida. A simulação usa um ' ...
    'modelo simplificado;\nvalide no equipamento com limite de segurança ' ...
    'e supervisão.\n']);

%% Gráficos
cores = lines(nRegras);

figure('Name', 'Ensaio e modelo FOPDT');
subplot(2, 1, 1);
plot(t, 100*un, 'LineWidth', 1.1); hold on;
plot([t(kDegrau) t(kDegrau)], [-5 105], 'k:');
grid on; ylim([-5 105]);
ylabel([NOME_U ' (%)']); xlabel('Tempo (s)');
title('Entrada registrada');
subplot(2, 1, 2);
plot(t, yBruto, 'Color', [0.75 0.75 0.75]); hold on;
plot(t, y, 'b', 'LineWidth', 1.3);
for i = 1:2
    if isfinite(erros(i))
        Lm = max(modelos{i, 2}, 0);
        plot(t(kDegrau) + tt, Y0 + deltaY*respostaFOPDT(Lm, modelos{i, 3}), ...
            '--', 'LineWidth', 1.3);
    end
end
grid on;
ylabel([NOME_Y ' (' UNIDADE_Y ')']); xlabel('Tempo (s)');
nomesModelo = modelos(isfinite(erros), 1)';
legend([{'Bruta', 'Filtrada'}, strcat('FOPDT', {' '}, nomesModelo)], 'Location', 'best');
title('Resposta usada na identificação');

figure('Name', 'Malha fechada simulada');
subplot(2, 1, 1);
hold on;
for i = 1:nRegras
    plot(tSim, ySim(:, i), 'Color', cores(i, :), 'LineWidth', 1.2);
end
plot(tSim, sp*ones(size(tSim)), 'k:', 'LineWidth', 1.1);
grid on;
ylabel([NOME_Y ' (' UNIDADE_Y ')']); xlabel('Tempo (s)');
legend([regras(:, 1)', {'Setpoint'}], 'Location', 'best');
title('Resposta simulada por regra de sintonia');
subplot(2, 1, 2);
hold on;
for i = 1:nRegras
    plot(tSim, 100*uSim(:, i), 'Color', cores(i, :));
end
grid on; ylim([-5 105]);
ylabel('Atuador (%)'); xlabel('Tempo (s)');
if usarTPO
    title('Saída do PID (duty do TPO)');
else
    title('Saída do PID aplicada ao atuador');
end
