%Request the data for force and displacement at each node.
%~~~~~~~~~~~~~~~~~~Description of variables~~~~~~~~~~~~~~~~~~~~~~~~~~
% n = Total number of nodes (one displacement degree of freedom per node)
% ne = Total number of three-node quadratic elements
% K = Global stiffness matrix
% A = Cross-sectional area of each element (m^2)
% L = Length of each element (m)
% E = Modulus of elasticity of each element (Pa)
% F_applied = Force applied at each node (N)
% F = Internal nodal force vector K*D (N), including support forces
% Reaction = Support reaction at each prescribed-displacement node (N)
% D = Displacement at each node (m)
% Stress_all, Strain_all = Element values separated by NaNs for plotting
% K_Reduced, F_Reduced, D_Reduced = System for unknown displacements
% Positive loads/displacements act along +x. Positive stress is tension.
%~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
clear;
clc;

%% Reading data from sheet 1 and sheet 2
% Find the workbook beside this script, regardless of the current folder.
codeFolder = fileparts(mfilename('fullpath'));
xlsFile = fullfile(codeFolder, 'Nodal data-WPS Office.xlsx');
T1 = readtable(xlsFile, 'Sheet', 'Nodal data', ...
    'VariableNamingRule', 'modify', 'UseExcel', false);
T2 = readtable(xlsFile, 'Sheet', 'Boundary condition', ...
    'VariableNamingRule', 'modify', 'UseExcel', false);

%% Choosing problem
pid = input('Input number of problem id (1 to 4 in the supplied workbook):\n');
validateattributes(pid, {'numeric'}, ...
    {'real', 'finite', 'scalar', 'integer', 'positive'});
if ~ismember('problemID', T1.Properties.VariableNames) || ...
        ~ismember('problemID', T2.Properties.VariableNames)
    error('Both input sheets must contain a problemID column.');
end
row = T1(T1.problemID == pid, :);
row2 = T2(T2.problemID == pid, :);
if height(row) ~= 1 || height(row2) ~= 1
    error('Problem %d must have exactly one row in each input sheet.', pid);
end

%% Extracting number of nodes and elements
n = read_number(row, 'n_nodes');
ne = read_number(row, 'n_elem');
if ne < 1 || ne ~= fix(ne) || n ~= 2*ne + 1
    error('For quadratic elements, n_elem must be positive and n_nodes = 2*n_elem + 1.');
end

%% Initialize the vectors and matrices
K = zeros(n);
A = zeros(ne, 1);
L = zeros(ne, 1);
E = zeros(ne, 1);
F = zeros(n, 1);
D = zeros(n, 1);

%% Read element data and compute the global stiffness matrix
idx = 1;
for index = 1:ne
    % Length, cross-section and modulus of each element
    L(index) = read_number(row, sprintf('L%d', index));
    A(index) = read_number(row, sprintf('A%d', index));
    E(index) = read_number(row, sprintf('E%d', index));
    if L(index) <= 0 || A(index) <= 0 || E(index) <= 0
        error('Element %d must have positive L, A and E.', index);
    end

    % The constant c = EA/(3L) for a three-node quadratic bar element
    constant = E(index)*A(index)/(3*L(index));
    if ~isfinite(constant) || constant <= 0
        error('Invalid stiffness in element %d. Check the input units and magnitudes.', index);
    end

    % 1st row
    K(idx,idx) = K(idx,idx) + 7*constant;
    K(idx,idx+1) = K(idx,idx+1) - 8*constant;
    K(idx,idx+2) = K(idx,idx+2) + constant;

    % 2nd row
    K(idx+1,idx) = K(idx+1,idx) - 8*constant;
    K(idx+1,idx+1) = K(idx+1,idx+1) + 16*constant;
    K(idx+1,idx+2) = K(idx+1,idx+2) - 8*constant;

    % 3rd row
    K(idx+2,idx) = K(idx+2,idx) + constant;
    K(idx+2,idx+1) = K(idx+2,idx+1) - 8*constant;
    K(idx+2,idx+2) = K(idx+2,idx+2) + 7*constant;

    idx = idx + 2;
end
if any(~isfinite(K(:)))
    error('Global stiffness overflow. Check the input units and magnitudes.');
end

%% Read force and displacement data at each node
selectionvector = [];       % Unknown displacements (to solve)
non_selectionvector = [];   % Known displacements (prescribed)
count1 = 0;
count2 = 0;
for k = 1:n
    flag = read_number(row2, sprintf('D%d_known', k));
    val = read_number(row2, sprintf('DF%d', k));

    % The workbook uses 0 for displacement and 1 for force.
    if flag == 0
        count1 = count1 + 1;
        D(k) = val;
        non_selectionvector(count1) = k;
    elseif flag == 1
        F(k) = val;
        count2 = count2 + 1;
        selectionvector(count2) = k;
    else
        error('D%d_known must be 0 (displacement) or 1 (force).', k);
    end
end
if isempty(non_selectionvector)
    error('Prescribe at least one displacement to prevent rigid-body motion.');
end
F_applied = F;  % Keep the applied loads before calculating K*D.

%% Reduce and solve the global system
K_Reduced = K(selectionvector, selectionvector);
F_Reduced = F(selectionvector) - ...
    K(selectionvector, non_selectionvector)*D(non_selectionvector);
if ~isempty(selectionvector)
    if rcond(K_Reduced) < 1e-14
        error('Reduced stiffness is singular or badly conditioned. Check properties and restraints.');
    end
    D_Reduced = K_Reduced \ F_Reduced;
    D(selectionvector) = D_Reduced;
end
if any(~isfinite(D))
    error('Computed displacement is not finite. Check the input units and magnitudes.');
end

% Calculate nodal forces and support reactions separately.
F = K*D;
Reaction = zeros(n, 1);
Reaction(non_selectionvector) = ...
    F(non_selectionvector) - F_applied(non_selectionvector);

%% Calculation of coordinates, strain and stress
Stress_all = [];
Strain_all = [];
Force_all = [];
X_all = [];
X_disp_all = [];
D_all = [];
X = zeros(n, 1);
Strain_L = nan(n, 1); Strain_R = nan(n, 1);
Stress_L = nan(n, 1); Stress_R = nan(n, 1);
Elem = zeros(n, 1);

idx = 1;
for index = 1:ne
    l = L(index);
    X(idx+1) = X(idx) + l/2;
    X(idx+2) = X(idx) + l;
    tempvec = [idx idx+1 idx+2];
    X_elem = X(tempvec);
    Strain_elem = zeros(3, 1);
    Stress_elem = zeros(3, 1);

    for e = 1:3
        % [B] matrix: derivative of the quadratic shape functions
        xloc = X_elem(e) - X(idx);
        N_der = (1/l)*[-3+4*xloc/l, 4-8*xloc/l, -1+4*xloc/l];
        Strain_elem(e) = N_der*D(tempvec);
        Stress_elem(e) = Strain_elem(e)*E(index);
    end

    % NaNs prevent joining values across element boundaries.
    X_all = [X_all; X_elem(:); NaN];
    Stress_all = [Stress_all; Stress_elem; NaN];
    Strain_all = [Strain_all; Strain_elem; NaN];
    Force_all = [Force_all; A(index)*Stress_elem; NaN];

    % Evaluate displacement inside the element using the same shape functions.
    xloc = linspace(0, l, 41).';
    t = xloc/l;
    N = [2*t.^2-3*t+1, 4*t-4*t.^2, 2*t.^2-t];
    X_disp_all = [X_disp_all; X(idx)+xloc; NaN];
    D_all = [D_all; N*D(tempvec); NaN];

    % Preserve different left/right values at a shared element boundary.
    Strain_R(tempvec(1:2)) = Strain_elem(1:2);
    Strain_L(tempvec(2:3)) = Strain_elem(2:3);
    Stress_R(tempvec(1:2)) = Stress_elem(1:2);
    Stress_L(tempvec(2:3)) = Stress_elem(2:3);
    Elem(tempvec) = index;  % A shared node belongs to the element on its right.
    idx = idx + 2;
end

% End nodes only have one adjacent element; repeat the available side.
Strain_L(1) = Strain_R(1); Stress_L(1) = Stress_R(1);
Strain_R(n) = Strain_L(n); Stress_R(n) = Stress_L(n);

%% All plots on one page
figure('Name', sprintf('Problem %d: Stress, Strain, Force, Displacement', pid), ...
    'NumberTitle', 'off', 'Color', 'w', 'Position', [100 100 1100 720]);

subplot(2,2,1);
plot(X_all, Stress_all, 'b-', 'LineWidth', 1.2);
xlabel('x coordinate (m)'); ylabel('Stress (Pa)');
title('Stress along x'); grid on;

subplot(2,2,2);
plot(X_all, Strain_all, 'r-', 'LineWidth', 1.2);
xlabel('x coordinate (m)'); ylabel('Strain');
title('Strain along x'); grid on;

subplot(2,2,3);
plot(X_all, Force_all, 'g-', 'LineWidth', 1.2);
xlabel('x coordinate (m)'); ylabel('Axial force (N)');
title('Axial force (tension positive)'); grid on;

subplot(2,2,4);
plot(X_disp_all, D_all, 'm-', 'LineWidth', 1.2);
hold on;
plot(X, D, 'mo', 'MarkerFaceColor', 'm');
hold off;
xlabel('x coordinate (m)'); ylabel('Displacement (m)');
title('Displacement vs. x'); grid on;

%% Write results to separate files; leave the input workbook unchanged
outputFolder = fullfile(codeFolder, 'results');
if ~isfolder(outputFolder)
    [ok, message] = mkdir(outputFolder);
    if ~ok, error('%s', message); end
end
Node = (1:n).';
T = table(Elem, Node, X, D, F_applied, Reaction, F, ...
    Strain_L, Strain_R, Stress_L, Stress_R, ...
    'VariableNames', {'Element', 'Node', 'x_m', 'Displacement_m', ...
    'AppliedForce_N', 'ReactionForce_N', 'NodalForce_N', ...
    'Strain_L', 'Strain_R', 'Stress_L_Pa', 'Stress_R_Pa'});
resultFile = fullfile(outputFolder, sprintf('problem%d.xlsx', pid));
csvFile = fullfile(outputFolder, sprintf('problem%d.csv', pid));
plotFile = fullfile(outputFolder, sprintf('problem%d.png', pid));
writetable(T, resultFile, 'Sheet', 'Nodal results', 'WriteMode', 'overwritesheet');
writetable(T, csvFile);
exportgraphics(gcf, plotFile, 'Resolution', 180);
disp(T);
fprintf('Results saved in %s\n', outputFolder);

%% Helper for numeric spreadsheet cells (including numbers stored as text)
function val = read_number(row, column)
if ~ismember(column, row.Properties.VariableNames)
    error('Input is missing column %s.', column);
end
val = row{1, column};
if iscell(val), val = val{1}; end
if ischar(val) || isstring(val), val = str2double(val); end
if ~isnumeric(val) || ~isscalar(val) || ~isreal(val) || ~isfinite(val)
    error('Column %s must contain a finite number, such as 250e9, not an expression.', column);
end
val = double(val);
end
