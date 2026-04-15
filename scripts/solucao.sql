-- =============================================================================
-- SISTEMA ACADEMICO — Script SQL Completo
-- Inclui: DDL, DCL, DML (carga de dados) e Queries de Relatório
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PARTE 1: SCHEMAS (Namespaces)
-- Criamos dois schemas para separar responsabilidades:
--   • seguranca  → controle de identidade e acesso dos usuários
--   • academico  → domínio do negócio acadêmico
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS seguranca;
CREATE SCHEMA IF NOT EXISTS academico;


-- =============================================================================
-- PARTE 2: DDL — CRIAÇÃO DAS TABELAS (Estrutura Normalizada em 3NF)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 seguranca.usuarios
-- Centraliza todos os atores do sistema (alunos e operadores como pessoas).
-- A coluna "ativo" implementa o Soft Delete: registros nunca são deletados
-- fisicamente, apenas marcados como inativos.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seguranca.usuarios (
    id_usuario      SERIAL          PRIMARY KEY,
    nome            VARCHAR(120)    NOT NULL,
    email           VARCHAR(120)    NOT NULL UNIQUE,
    endereco        VARCHAR(200),
    tipo_usuario    VARCHAR(20)     NOT NULL DEFAULT 'aluno'
                        CHECK (tipo_usuario IN ('aluno','coordenador','secretaria')),
    ativo           BOOLEAN         NOT NULL DEFAULT TRUE,
    criado_em       TIMESTAMP       NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2.2 academico.docentes
-- Cadastro de professores/docentes. Separado de usuários pois docentes não
-- precisam de login no sistema pelos requisitos atuais.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico.docentes (
    id_docente      SERIAL          PRIMARY KEY,
    nome_docente    VARCHAR(120)    NOT NULL,
    ativo           BOOLEAN         NOT NULL DEFAULT TRUE,
    criado_em       TIMESTAMP       NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2.3 academico.operadores_pedagogicos
-- Secretários/coordenadores que fazem as matrículas.
-- "matricula_operador" vem da planilha legada (OP9001, OP9002, ...).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico.operadores_pedagogicos (
    id_operador             SERIAL      PRIMARY KEY,
    matricula_operador      VARCHAR(10) NOT NULL UNIQUE,
    nome_operador           VARCHAR(120),
    ativo                   BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em               TIMESTAMP   NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2.4 academico.disciplinas
-- Catálogo de serviços/disciplinas. cod_servico = ADS101, ADS102, etc.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico.disciplinas (
    id_disciplina       SERIAL      PRIMARY KEY,
    cod_servico         VARCHAR(10) NOT NULL UNIQUE,
    nome_disciplina     VARCHAR(100) NOT NULL,
    carga_horaria       INTEGER     NOT NULL CHECK (carga_horaria > 0),
    ativo               BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em           TIMESTAMP   NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2.5 academico.turmas
-- Uma turma vincula uma disciplina a um docente em um ciclo de calendário.
-- FK para disciplinas e docentes garantem integridade referencial.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico.turmas (
    id_turma            SERIAL      PRIMARY KEY,
    id_disciplina       INTEGER     NOT NULL
                            REFERENCES academico.disciplinas(id_disciplina),
    id_docente          INTEGER     NOT NULL
                            REFERENCES academico.docentes(id_docente),
    ciclo_calendario    VARCHAR(10) NOT NULL,
    ativo               BOOLEAN     NOT NULL DEFAULT TRUE,
    criado_em           TIMESTAMP   NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2.6 academico.matriculas
-- Tabela central: registra o vínculo aluno-turma-operador com a nota final.
-- cod_matricula preserva o ID original da planilha legada (ex: 2026001).
-- Soft Delete via coluna "ativo": DELETE físico é desaconselhado aqui para
-- preservar o histórico de notas e matrículas.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS academico.matriculas (
    id_matricula        SERIAL          PRIMARY KEY,
    cod_matricula       VARCHAR(10)     NOT NULL,
    id_usuario          INTEGER         NOT NULL
                            REFERENCES seguranca.usuarios(id_usuario),
    id_turma            INTEGER         NOT NULL
                            REFERENCES academico.turmas(id_turma),
    id_operador         INTEGER         NOT NULL
                            REFERENCES academico.operadores_pedagogicos(id_operador),
    data_ingresso       DATE            NOT NULL,
    score_final         NUMERIC(4,2)    CHECK (score_final BETWEEN 0 AND 10),
    ativo               BOOLEAN         NOT NULL DEFAULT TRUE,
    criado_em           TIMESTAMP       NOT NULL DEFAULT NOW(),
    atualizado_em       TIMESTAMP       NOT NULL DEFAULT NOW(),
    -- Unicidade: um aluno não pode estar matriculado na mesma turma duas vezes
    UNIQUE (id_usuario, id_turma)
);

-- Índice para acelerar buscas por aluno
CREATE INDEX IF NOT EXISTS idx_matriculas_usuario
    ON academico.matriculas(id_usuario);

-- Índice para acelerar buscas por turma
CREATE INDEX IF NOT EXISTS idx_matriculas_turma
    ON academico.matriculas(id_turma);


-- =============================================================================
-- PARTE 3: DCL — GOVERNANÇA E SEGURANÇA
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Criar os roles (perfis)
-- -----------------------------------------------------------------------------

-- Verifica e cria professor_role
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'professor_role') THEN
        CREATE ROLE professor_role;
    END IF;
END$$;

-- Verifica e cria coordenador_role
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'coordenador_role') THEN
        CREATE ROLE coordenador_role;
    END IF;
END$$;

-- -----------------------------------------------------------------------------
-- 3.2 professor_role
-- Permissões restritas:
--   • Pode fazer SELECT em matriculas e turmas para ver contexto
--   • Pode UPDATE apenas na coluna score_final de matriculas
--   • NÃO tem acesso ao schema seguranca (dados pessoais / email)
-- -----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA academico TO professor_role;

-- Leitura de turmas e disciplinas (contexto necessário)
GRANT SELECT ON academico.turmas       TO professor_role;
GRANT SELECT ON academico.disciplinas  TO professor_role;
GRANT SELECT ON academico.docentes     TO professor_role;

-- Leitura de matriculas (para saber quais alunos estão na turma)
-- mas SEM acesso ao schema seguranca.usuarios (email protegido)
GRANT SELECT ON academico.matriculas   TO professor_role;

-- Atualização restrita SOMENTE à coluna de nota
GRANT UPDATE (score_final, atualizado_em)
    ON academico.matriculas TO professor_role;

-- Privacidade: professor_role NÃO recebe USAGE em seguranca
-- Logo, não consegue fazer SELECT em seguranca.usuarios (inclui email)
-- Confirma revogação explícita
REVOKE ALL ON SCHEMA seguranca FROM professor_role;
REVOKE ALL ON ALL TABLES IN SCHEMA seguranca FROM professor_role;

-- -----------------------------------------------------------------------------
-- 3.3 coordenador_role
-- Acesso total a ambos os schemas.
-- -----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA academico TO coordenador_role;
GRANT USAGE ON SCHEMA seguranca TO coordenador_role;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA academico TO coordenador_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA seguranca TO coordenador_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA academico TO coordenador_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA seguranca TO coordenador_role;

-- Garante que novas tabelas futuras também sejam cobertas
ALTER DEFAULT PRIVILEGES IN SCHEMA academico
    GRANT ALL ON TABLES TO coordenador_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA seguranca
    GRANT ALL ON TABLES TO coordenador_role;


-- =============================================================================
-- PARTE 4: DML — CARGA DE DADOS (População a partir da planilha legada)
-- Os dados estão na ordem correta de dependência: primeiro as entidades
-- "pai", depois as "filhas" que referenciam as anteriores.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 seguranca.usuarios (alunos)
-- -----------------------------------------------------------------------------
INSERT INTO seguranca.usuarios (nome, email, endereco, tipo_usuario) VALUES
    ('Ana Beatriz Lima',    'ana.lima@aluno.edu.br',       'Braganca Paulista/SP', 'aluno'),
    ('Bruno Henrique Souza','bruno.souza@aluno.edu.br',    'Atibaia/SP',           'aluno'),
    ('Camila Ferreira',     'camila.ferreira@aluno.edu.br','Jundiai/SP',           'aluno'),
    ('Diego Martins',       'diego.martins@aluno.edu.br',  'Campinas/SP',          'aluno'),
    ('Eduarda Nunes',       'eduarda.nunes@aluno.edu.br',  'Itatiba/SP',           'aluno'),
    ('Felipe Araujo',       'felipe.araujo@aluno.edu.br',  'Louveira/SP',          'aluno'),
    ('Gabriela Torres',     'gabriela.torres@aluno.edu.br','Nazare Paulista/SP',   'aluno'),
    ('Helena Rocha',        'helena.rocha@aluno.edu.br',   'Piracaia/SP',          'aluno'),
    ('Igor Santana',        'igor.santana@aluno.edu.br',   'Jarinu/SP',            'aluno')
ON CONFLICT (email) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.2 academico.docentes
-- -----------------------------------------------------------------------------
INSERT INTO academico.docentes (nome_docente) VALUES
    ('Prof. Carlos Mendes'),
    ('Profa. Juliana Castro'),
    ('Prof. Eduardo Pires'),
    ('Prof. Renato Alves'),
    ('Profa. Marina Lopes'),
    ('Prof. Ricardo Faria')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.3 academico.operadores_pedagogicos
-- Identificados pelo campo Matricula_Operador_Pedagogico da planilha.
-- -----------------------------------------------------------------------------
INSERT INTO academico.operadores_pedagogicos (matricula_operador, nome_operador) VALUES
    ('OP8999', 'Operador Pedagogico 8999'),
    ('OP9000', 'Operador Pedagogico 9000'),
    ('OP9001', 'Operador Pedagogico 9001'),
    ('OP9002', 'Operador Pedagogico 9002'),
    ('OP9003', 'Operador Pedagogico 9003'),
    ('OP9004', 'Operador Pedagogico 9004')
ON CONFLICT (matricula_operador) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.4 academico.disciplinas
-- -----------------------------------------------------------------------------
INSERT INTO academico.disciplinas (cod_servico, nome_disciplina, carga_horaria) VALUES
    ('ADS101', 'Banco de Dados',           80),
    ('ADS102', 'Engenharia de Software',   80),
    ('ADS103', 'Algoritmos',               60),
    ('ADS104', 'Redes de Computadores',    60),
    ('ADS105', 'Sistemas Operacionais',    60),
    ('ADS106', 'Estruturas de Dados',      80)
ON CONFLICT (cod_servico) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.5 academico.turmas
-- Vincula disciplina + docente + ciclo.
-- Cada combinação única da planilha legada gera uma turma.
-- -----------------------------------------------------------------------------
INSERT INTO academico.turmas (id_disciplina, id_docente, ciclo_calendario)
SELECT d.id_disciplina, dc.id_docente, t.ciclo
FROM (VALUES
    ('ADS101', 'Prof. Carlos Mendes',    '2026/1'),
    ('ADS102', 'Profa. Juliana Castro',  '2026/1'),
    ('ADS103', 'Prof. Renato Alves',     '2026/1'),
    ('ADS104', 'Profa. Marina Lopes',    '2026/1'),
    ('ADS105', 'Prof. Eduardo Pires',    '2026/1'),
    ('ADS106', 'Prof. Ricardo Faria',    '2026/1'),
    ('ADS101', 'Prof. Carlos Mendes',    '2025/2'),
    ('ADS102', 'Profa. Juliana Castro',  '2025/2'),
    ('ADS103', 'Prof. Renato Alves',     '2025/2'),
    ('ADS104', 'Profa. Marina Lopes',    '2025/2'),
    ('ADS105', 'Prof. Eduardo Pires',    '2025/2'),
    ('ADS106', 'Prof. Ricardo Faria',    '2025/2')
) AS t(cod_servico, nome_docente, ciclo)
JOIN academico.disciplinas d  ON d.cod_servico    = t.cod_servico
JOIN academico.docentes    dc ON dc.nome_docente  = t.nome_docente
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.6 academico.matriculas
-- Carga dos 24 registros da planilha, usando subqueries para resolver os IDs.
-- Cada linha representa um aluno inscrito em uma turma específica.
-- -----------------------------------------------------------------------------
INSERT INTO academico.matriculas
    (cod_matricula, id_usuario, id_turma, id_operador, data_ingresso, score_final)
SELECT
    m.cod,
    u.id_usuario,
    t.id_turma,
    op.id_operador,
    m.data_ingresso::DATE,
    m.score
FROM (VALUES
    -- ciclo 2026/1
    ('2026001','ana.lima@aluno.edu.br',        'ADS101','OP9001','2026-01-20', 9.1),
    ('2026001','ana.lima@aluno.edu.br',        'ADS102','OP9001','2026-01-20', 8.4),
    ('2026001','ana.lima@aluno.edu.br',        'ADS105','OP9001','2026-01-20', 8.9),
    ('2026002','bruno.souza@aluno.edu.br',     'ADS101','OP9002','2026-01-21', 7.3),
    ('2026002','bruno.souza@aluno.edu.br',     'ADS103','OP9002','2026-01-21', 6.8),
    ('2026002','bruno.souza@aluno.edu.br',     'ADS104','OP9002','2026-01-21', 7.0),
    ('2026003','camila.ferreira@aluno.edu.br', 'ADS101','OP9001','2026-01-22', 5.9),
    ('2026003','camila.ferreira@aluno.edu.br', 'ADS102','OP9001','2026-01-22', 7.5),
    ('2026003','camila.ferreira@aluno.edu.br', 'ADS106','OP9001','2026-01-22', 6.1),
    ('2026004','diego.martins@aluno.edu.br',   'ADS103','OP9003','2026-01-23', 4.7),
    ('2026004','diego.martins@aluno.edu.br',   'ADS104','OP9003','2026-01-23', 6.2),
    ('2026004','diego.martins@aluno.edu.br',   'ADS105','OP9003','2026-01-23', 5.8),
    ('2026005','eduarda.nunes@aluno.edu.br',   'ADS102','OP9002','2026-01-24', 9.5),
    ('2026005','eduarda.nunes@aluno.edu.br',   'ADS104','OP9002','2026-01-24', 8.1),
    ('2026005','eduarda.nunes@aluno.edu.br',   'ADS106','OP9002','2026-01-24', 8.7),
    ('2026006','felipe.araujo@aluno.edu.br',   'ADS101','OP9004','2026-01-25', 6.4),
    ('2026006','felipe.araujo@aluno.edu.br',   'ADS103','OP9004','2026-01-25', 5.6),
    ('2026006','felipe.araujo@aluno.edu.br',   'ADS105','OP9004','2026-01-25', 6.9),
    -- ciclo 2025/2
    ('2025010','gabriela.torres@aluno.edu.br', 'ADS101','OP8999','2025-08-05', 6.4),
    ('2025010','gabriela.torres@aluno.edu.br', 'ADS102','OP8999','2025-08-05', 7.1),
    ('2025011','helena.rocha@aluno.edu.br',    'ADS103','OP8999','2025-08-06', 8.8),
    ('2025011','helena.rocha@aluno.edu.br',    'ADS104','OP8999','2025-08-06', 7.9),
    ('2025012','igor.santana@aluno.edu.br',    'ADS105','OP9000','2025-08-07', 5.5),
    ('2025012','igor.santana@aluno.edu.br',    'ADS106','OP9000','2025-08-07', 6.3)
) AS m(cod, email, cod_servico, mat_op, data_ingresso, score)
JOIN seguranca.usuarios                  u  ON u.email               = m.email
JOIN academico.disciplinas               di ON di.cod_servico         = m.cod_servico
JOIN academico.operadores_pedagogicos    op ON op.matricula_operador  = m.mat_op
JOIN academico.turmas                    t  ON t.id_disciplina = di.id_disciplina
                                           AND t.ciclo_calendario = (
                                               CASE
                                                   WHEN m.data_ingresso >= '2026-01-01' THEN '2026/1'
                                                   ELSE '2025/2'
                                               END
                                           )
ON CONFLICT (id_usuario, id_turma) DO NOTHING;


-- =============================================================================
-- PARTE 5: QUERIES DE RELATÓRIO
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Query 1: Listagem de Matriculados no ciclo 2026/1
-- Retorna: nome do aluno, nome da disciplina e ciclo
-- Filtro: apenas ciclo 2026/1
-- ---------------------------------------------------------------------------
SELECT
    u.nome                      AS aluno,
    di.nome_disciplina          AS disciplina,
    t.ciclo_calendario          AS ciclo
FROM academico.matriculas m
JOIN seguranca.usuarios          u  ON u.id_usuario    = m.id_usuario
JOIN academico.turmas            t  ON t.id_turma      = m.id_turma
JOIN academico.disciplinas       di ON di.id_disciplina = t.id_disciplina
WHERE t.ciclo_calendario = '2026/1'
  AND m.ativo = TRUE
ORDER BY u.nome, di.nome_disciplina;


-- ---------------------------------------------------------------------------
-- Query 2: Baixo Desempenho — disciplinas com média < 6.0
-- Usa GROUP BY + HAVING para filtrar após agregação
-- ---------------------------------------------------------------------------
SELECT
    di.nome_disciplina          AS disciplina,
    ROUND(AVG(m.score_final), 2) AS media_notas
FROM academico.matriculas m
JOIN academico.turmas      t  ON t.id_turma       = m.id_turma
JOIN academico.disciplinas di ON di.id_disciplina = t.id_disciplina
WHERE m.ativo = TRUE
GROUP BY di.nome_disciplina
HAVING AVG(m.score_final) < 6.0
ORDER BY media_notas;


-- ---------------------------------------------------------------------------
-- Query 3: Alocação de Docentes — todos os docentes e suas turmas
-- LEFT JOIN garante que docentes sem turmas também aparecem
-- ---------------------------------------------------------------------------
SELECT
    dc.nome_docente             AS docente,
    di.nome_disciplina          AS disciplina,
    t.ciclo_calendario          AS ciclo
FROM academico.docentes dc
LEFT JOIN academico.turmas       t  ON t.id_docente    = dc.id_docente
                                   AND t.ativo = TRUE
LEFT JOIN academico.disciplinas  di ON di.id_disciplina = t.id_disciplina
ORDER BY dc.nome_docente, t.ciclo_calendario;


-- ---------------------------------------------------------------------------
-- Query 4: Destaque Acadêmico — maior nota em Banco de Dados
-- Usa subconsulta para encontrar o MAX e depois busca o aluno correspondente
-- ---------------------------------------------------------------------------
SELECT
    u.nome          AS aluno,
    m.score_final   AS maior_nota
FROM academico.matriculas m
JOIN seguranca.usuarios          u  ON u.id_usuario    = m.id_usuario
JOIN academico.turmas            t  ON t.id_turma      = m.id_turma
JOIN academico.disciplinas       di ON di.id_disciplina = t.id_disciplina
WHERE di.nome_disciplina = 'Banco de Dados'
  AND m.ativo = TRUE
  AND m.score_final = (
      -- Subconsulta: encontra o valor máximo de nota em Banco de Dados
      SELECT MAX(m2.score_final)
      FROM academico.matriculas  m2
      JOIN academico.turmas       t2  ON t2.id_turma       = m2.id_turma
      JOIN academico.disciplinas  di2 ON di2.id_disciplina = t2.id_disciplina
      WHERE di2.nome_disciplina = 'Banco de Dados'
        AND m2.ativo = TRUE
  )
ORDER BY u.nome;


-- =============================================================================
-- FIM DO SCRIPT
-- =============================================================================