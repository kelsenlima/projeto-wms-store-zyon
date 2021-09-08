set feedback off
set serveroutput on
set pagesize 0
set ver off
set echo off

spool /u01/app/oracle/product/11.2.0/orcl/dbs/reorg61.log

-- Seção do Cabeçalho de Script
-- ==============================================

-- functions and procedures

CREATE OR REPLACE PROCEDURE mgmt$reorg_sendMsg (msg IN VARCHAR2) IS
    msg1 VARCHAR2(1020);
    len INTEGER := length(msg);
    i INTEGER := 1;
BEGIN
    dbms_output.enable (1000000);

    LOOP
      msg1 := SUBSTR (msg, i, 255);
      dbms_output.put_line (msg1);
      len := len - 255;
      i := i + 255;
    EXIT WHEN len <= 0;
    END LOOP;
END mgmt$reorg_sendMsg;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_errorExit (msg IN VARCHAR2) IS
BEGIN
    mgmt$reorg_sendMsg (msg);
    mgmt$reorg_sendMsg ('errorExit!');
END mgmt$reorg_errorExit;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_errorExitOraError (msg IN VARCHAR2, errMsg IN VARCHAR2) IS
BEGIN
    mgmt$reorg_sendMsg (msg);
    mgmt$reorg_sendMsg (errMsg);
    mgmt$reorg_sendMsg ('errorExitOraError!');
END mgmt$reorg_errorExitOraError;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_checkDBAPrivs 
AUTHID CURRENT_USER IS
    granted_role REAL := 0;
    user_name user_users.username%type;
BEGIN
SELECT USERNAME INTO user_name FROM USER_USERS;
    EXECUTE IMMEDIATE 'SELECT 1 FROM SYS.DBA_ROLE_PRIVS WHERE GRANTED_ROLE = ''DBA'' AND GRANTEE = :1'
      INTO granted_role       USING user_name;
EXCEPTION
    WHEN OTHERS THEN
       IF SQLCODE = -01403 OR SQLCODE = -00942  THEN
      mgmt$reorg_sendMsg ( 'ADVERTÊNCIA: verificando privilégios... Nome do Usuário: ' || user_name);
      mgmt$reorg_sendMsg ( 'O usuário não tem privilégios de DBA. ' );
      mgmt$reorg_sendMsg ( 'O script falhará se tentar executar operações para as quais o usuário não tem o privilégio apropriado. ' );
      END IF;
END mgmt$reorg_checkDBAPrivs;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_setUpJobTable (script_id IN INTEGER, job_table IN VARCHAR2, step_num OUT INTEGER)
AUTHID CURRENT_USER IS
    ctsql_text VARCHAR2(200) := 'CREATE TABLE ' || job_table || '(SCRIPT_ID NUMBER, LAST_STEP NUMBER, unique (SCRIPT_ID))';
    itsql_text VARCHAR2(200) := 'INSERT INTO ' || job_table || ' (SCRIPT_ID, LAST_STEP) values (:1, :2)';
    stsql_text VARCHAR2(200) := 'SELECT last_step FROM ' || job_table || ' WHERE script_id = :1';

    TYPE CurTyp IS REF CURSOR;  -- define weak REF CURSOR type
    stsql_cur CurTyp;  -- declare cursor variable

BEGIN
    step_num := 0;
    BEGIN
      EXECUTE IMMEDIATE ctsql_text;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;

    BEGIN
      OPEN stsql_cur FOR  -- open cursor variable
        stsql_text USING  script_id;
      FETCH stsql_cur INTO step_num;
      IF stsql_cur%FOUND THEN
        NULL;
      ELSE
        EXECUTE IMMEDIATE itsql_text USING script_id, step_num;
        COMMIT;
        step_num := 1;
      END IF;
      CLOSE stsql_cur;
    EXCEPTION
      WHEN OTHERS THEN
        mgmt$reorg_errorExit ('ERRO ao selecionar ou inserir dados na tabela: ' || job_table);
        return;
    END;

    return;

EXCEPTION
      WHEN OTHERS THEN
        mgmt$reorg_errorExit ('ERRO ao acessar a tabela: ' || job_table);
        return;
END mgmt$reorg_setUpJobTable;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_deleteJobTableEntry(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN INTEGER, highest_step IN INTEGER)
AUTHID CURRENT_USER IS
    delete_text VARCHAR2(200) := 'DELETE FROM ' || job_table || ' WHERE SCRIPT_ID = :1';
BEGIN

    IF step_num <= highest_step THEN
      return;
    END IF;

    BEGIN
      EXECUTE IMMEDIATE delete_text USING script_id;
      IF SQL%NOTFOUND THEN
        mgmt$reorg_errorExit ('ERRO ao deletar a entrada da tabela: ' || job_table);
        return;
      END IF;
    EXCEPTION
        WHEN OTHERS THEN
          mgmt$reorg_errorExit ('ERRO ao deletar a entrada da tabela: ' || job_table);
          return;
    END;

    COMMIT;
END mgmt$reorg_deleteJobTableEntry;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_setStep (script_id IN INTEGER, job_table IN VARCHAR2, step_num IN INTEGER)
AUTHID CURRENT_USER IS
    update_text VARCHAR2(200) := 'UPDATE ' || job_table || ' SET last_step = :1 WHERE script_id = :2';
BEGIN
    -- update job table
    EXECUTE IMMEDIATE update_text USING step_num, script_id;
    IF SQL%NOTFOUND THEN
      mgmt$reorg_sendMsg ('EXCEÇÃO NÃO ENCONTRADA EM sql_text: ' || update_text);
      mgmt$reorg_errorExit ('ERRO ao acessar a tabela: ' || job_table);
      return;
    END IF;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
      mgmt$reorg_errorExit ('ERRO ao acessar a tabela: ' || job_table);
      return;
END mgmt$reorg_setStep;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_dropTbsp (tbsp_name IN VARCHAR2)
AUTHID CURRENT_USER IS
  sql_text VARCHAR2(2000) := 'SELECT count(*) FROM sys.seg$ s, sys.ts$ t ' ||
                             'WHERE s.ts# = t.ts# and t.name = :1 and rownum = 1';
  seg_count INTEGER := 1;
  tbsp_name_r VARCHAR2(30);
BEGIN
  tbsp_name_r := REPLACE(tbsp_name, '"', '');
  EXECUTE IMMEDIATE sql_text INTO seg_count USING tbsp_name_r;
  IF (seg_count = 0) THEN
    mgmt$reorg_sendMsg ('DROP TABLESPACE ' || tbsp_name || ' INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS');
    EXECUTE IMMEDIATE 'DROP TABLESPACE ' || tbsp_name || ' INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS';
  ELSE
    mgmt$reorg_sendMsg ('DROP TABLESPACE ' || tbsp_name);
    EXECUTE IMMEDIATE 'DROP TABLESPACE ' || tbsp_name;
  END IF;
END mgmt$reorg_dropTbsp;
/

CREATE OR REPLACE PROCEDURE mgmt$step_1_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 1 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('CREATE  SMALLFILE  TABLESPACE "ORAINT_REORG0" DATAFILE ''+DGDATA'' SIZE 32740M REUSE  AUTOEXTEND ON NEXT 3072M MAXSIZE 32740M LOGGING  EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT  AUTO ');
      EXECUTE IMMEDIATE 'CREATE  SMALLFILE  TABLESPACE "ORAINT_REORG0" DATAFILE ''+DGDATA'' SIZE 32740M REUSE  AUTOEXTEND ON NEXT 3072M MAXSIZE 32740M LOGGING  EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT  AUTO ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_1_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_2_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 2 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER USER "ORAINT" DEFAULT TABLESPACE "ORAINT_REORG0"');
      EXECUTE IMMEDIATE 'ALTER USER "ORAINT" DEFAULT TABLESPACE "ORAINT_REORG0"';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_2_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_3_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 3 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."VOLUMEDETALHE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."VOLUMEDETALHE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_3_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_4_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 4 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_VOLUMEDETALHE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_VOLUMEDETALHE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_4_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_5_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 5 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VOLUMEDETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VOLUMEDETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_5_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_6_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 6 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."VOLUME" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."VOLUME" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_6_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_7_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 7 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_VOLUME" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_VOLUME" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_7_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_8_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 8 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_8_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_9_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 9 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."VERSAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."VERSAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_9_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_10_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 10 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_VERSAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_VERSAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_10_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_11_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 11 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VERSAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"VERSAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_11_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_12_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 12 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TMP_INTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TMP_INTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_12_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_13_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 13 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPKTMP_INTEGRACAO" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPKTMP_INTEGRACAO" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_13_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_14_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 14 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TMP_INTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TMP_INTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_14_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_15_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 15 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOUC" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOUC" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_15_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_16_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 16 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOUC" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOUC" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_16_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_17_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 17 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOUC"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOUC"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_17_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_18_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 18 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOSISTEMA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOSISTEMA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_18_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_19_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 19 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOSISTEMA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOSISTEMA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_19_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_20_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 20 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOSISTEMA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOSISTEMA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_20_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_21_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 21 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOMODERADOR" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOMODERADOR" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_21_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_22_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 22 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOMODERADOR" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOMODERADOR" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_22_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_23_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 23 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOMODERADOR"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOMODERADOR"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_23_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_24_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 24 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOINTEGRACAOTABELA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOINTEGRACAOTABELA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_24_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_25_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 25 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAOTABELA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAOTABELA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_25_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_26_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 26 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAOTABELA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAOTABELA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_26_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_27_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 27 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOINTEGRACAOEMPRESA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOINTEGRACAOEMPRESA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_27_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_28_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 28 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAOEMPRESA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAOEMPRESA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_28_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_29_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 29 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAOEMPRESA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAOEMPRESA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_29_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_30_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 30 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TIPOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TIPOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_30_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_31_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 31 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_TI_SRESPONSAVEL" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_TI_SRESPONSAVEL" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_31_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_32_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 32 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TIPOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_32_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_33_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 33 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TIPOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_33_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_34_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 34 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."TABELACAMPO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."TABELACAMPO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_34_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_35_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 35 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_TABELACAMPO_ORDEMCAMPO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_TABELACAMPO_ORDEMCAMPO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_35_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_36_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 36 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_TABELACAMPO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_TABELACAMPO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_36_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_37_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 37 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TABELACAMPO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"TABELACAMPO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_37_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_38_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 38 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."SISTEMABANCOVERSAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."SISTEMABANCOVERSAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_38_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_39_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 39 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_SISTEMABANCOVERSAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_SISTEMABANCOVERSAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_39_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_40_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 40 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"SISTEMABANCOVERSAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"SISTEMABANCOVERSAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_40_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_41_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 41 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."SISTEMA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."SISTEMA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_41_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_42_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 42 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_TSISTEMA_SISTEMA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_TSISTEMA_SISTEMA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_42_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_43_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 43 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_SISTEMA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_SISTEMA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_43_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_44_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 44 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"SISTEMA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"SISTEMA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_44_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_45_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 45 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."ROMANEIO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."ROMANEIO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_45_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_46_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 46 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_ROMANEIO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_ROMANEIO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_46_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_47_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 47 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ROMANEIO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ROMANEIO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_47_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_48_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 48 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."RESERVA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."RESERVA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_48_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_49_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 49 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_RESERVA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_RESERVA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_49_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_50_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 50 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RESERVA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RESERVA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_50_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_51_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 51 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."RDASEQUENCIA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."RDASEQUENCIA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_51_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_52_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 52 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_RDASEQUENCIA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_RDASEQUENCIA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_52_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_53_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 53 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDASEQUENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDASEQUENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_53_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_54_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 54 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."RDAIMAGEM" MOVE TABLESPACE "ORAINT_REORG0" LOB ("IMAGEM") STORE AS (TABLESPACE "ORAINT_REORG0") ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."RDAIMAGEM" MOVE TABLESPACE "ORAINT_REORG0" LOB ("IMAGEM") STORE AS (TABLESPACE "ORAINT_REORG0") ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_54_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_55_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 55 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_RDAIMAGEM" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_RDAIMAGEM" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_55_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_56_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 56 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDAIMAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDAIMAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_56_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_57_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 57 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."RDA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."RDA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_57_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_58_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 58 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_RDA_DOCUMENTODETALHE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_RDA_DOCUMENTODETALHE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_58_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_59_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 59 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_RDA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_RDA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_59_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_60_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 60 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"RDA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_60_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_61_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 61 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."PROVEDOR" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."PROVEDOR" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_61_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_62_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 62 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_CODIGOPROVEDOR" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_CODIGOPROVEDOR" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_62_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_63_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 63 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PROVEDOR"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PROVEDOR"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_63_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_64_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 64 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."PRODUTODETALHE" MOVE TABLESPACE "ORAINT_REORG0" LOB ("IMAGEMPRODUTO") STORE AS (TABLESPACE "ORAINT_REORG0") ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."PRODUTODETALHE" MOVE TABLESPACE "ORAINT_REORG0" LOB ("IMAGEMPRODUTO") STORE AS (TABLESPACE "ORAINT_REORG0") ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_64_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_65_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 65 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_PRODUTODETALHE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_PRODUTODETALHE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_65_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_66_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 66 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTODETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTODETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_66_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_67_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 67 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."PRODUTOCOMPONENTE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."PRODUTOCOMPONENTE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_67_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_68_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 68 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_PRODUTOCOMPONENTE" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_PRODUTOCOMPONENTE" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_68_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_69_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 69 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTOCOMPONENTE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTOCOMPONENTE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_69_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_70_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 70 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."PRODUTO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."PRODUTO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_70_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_71_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 71 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_PRODUTO_CPRODUTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_PRODUTO_CPRODUTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_71_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_72_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 72 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_PRODUTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_PRODUTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_72_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_73_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 73 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PRODUTO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_73_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_74_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 74 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."PARAMETROINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."PARAMETROINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_74_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_75_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 75 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_PARAMETROINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_PARAMETROINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_75_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_76_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 76 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PARAMETROINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"PARAMETROINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_76_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_77_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 77 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."MOVIMENTOESTOQUE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."MOVIMENTOESTOQUE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_77_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_78_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 78 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_MOVIMENTOESTOQUE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_MOVIMENTOESTOQUE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_78_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_79_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 79 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MOVIMENTOESTOQUE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MOVIMENTOESTOQUE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_79_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_80_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 80 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."MODERADOR" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."MODERADOR" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_80_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_81_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 81 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_MODERADOR_NOMECAMPO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_MODERADOR_NOMECAMPO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_81_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_82_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 82 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_MODERADOR" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_MODERADOR" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_82_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_83_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 83 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MODERADOR"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MODERADOR"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_83_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_84_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 84 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."MENSAGEM" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."MENSAGEM" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_84_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_85_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 85 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_MENSAGEM_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_MENSAGEM_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_85_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_86_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 86 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_MENSAGEM_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_MENSAGEM_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_86_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_87_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 87 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_MENSAGEM" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_MENSAGEM" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_87_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_88_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 88 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MENSAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"MENSAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_88_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_89_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 89 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."INVENTARIO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."INVENTARIO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_89_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_90_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 90 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_INVENTARIO_CPRODUTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_INVENTARIO_CPRODUTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_90_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_91_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 91 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_INVENTARIO_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_INVENTARIO_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_91_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_92_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 92 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_INVENTARIO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_INVENTARIO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_92_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_93_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 93 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INVENTARIO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INVENTARIO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_93_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_94_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 94 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."INTEGRACAOHISTORICO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."INTEGRACAOHISTORICO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_94_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_95_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 95 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_IHISTORICO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_IHISTORICO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_95_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_96_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 96 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_IHISTORICO_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_IHISTORICO_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_96_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_97_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 97 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_INTEGRACAOHISTORICO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_INTEGRACAOHISTORICO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_97_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_98_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 98 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INTEGRACAOHISTORICO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INTEGRACAOHISTORICO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_98_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_99_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 99 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."INTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."INTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_99_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_100_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 100 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_INTEGRACAO_DATALOG" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_INTEGRACAO_DATALOG" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_100_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_101_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 101 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_INTEGRACAO_DPROCESSAMENTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_INTEGRACAO_DPROCESSAMENTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_101_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_102_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 102 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_INTEGRACAO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_INTEGRACAO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_102_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_103_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 103 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_INTEGRACAO_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_INTEGRACAO_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_103_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_104_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 104 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_INTEGRACAO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_INTEGRACAO_EINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_104_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_105_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 105 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_INTEGRACAO_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_INTEGRACAO_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_105_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_106_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 106 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_INTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_106_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_107_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 107 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"INTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_107_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_108_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 108 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."FLUXOTIPOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."FLUXOTIPOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_108_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_109_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 109 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_FTIPOINT_FINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_FTIPOINT_FINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_109_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_110_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 110 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_FTIPOINT_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_FTIPOINT_TINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_110_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_111_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 111 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_FLUXOTIPOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_FLUXOTIPOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_111_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_112_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 112 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"FLUXOTIPOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"FLUXOTIPOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_112_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_113_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 113 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."FLUXOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."FLUXOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_113_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_114_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 114 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_FINTEGRACAO_SSISTEMA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_FINTEGRACAO_SSISTEMA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_114_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_115_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 115 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_FLUXOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_FLUXOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_115_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_116_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 116 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"FLUXOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"FLUXOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_116_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_117_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 117 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."ESTADOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."ESTADOINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_117_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_118_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 118 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_ESTADOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_ESTADOINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_118_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_119_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 119 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ESTADOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ESTADOINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_119_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_120_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 120 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."ESTABELECIMENTO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."ESTABELECIMENTO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_120_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_121_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 121 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_ESTAB_FINTEGRACAOERP" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_ESTAB_FINTEGRACAOERP" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_121_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_122_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 122 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_ESTABELECIMENTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_ESTABELECIMENTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_122_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_123_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 123 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ESTABELECIMENTO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ESTABELECIMENTO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_123_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_124_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 124 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."ERROINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."ERROINTEGRACAO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_124_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_125_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 125 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_ERROINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_ERROINTEGRACAO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_125_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_126_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 126 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ERROINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"ERROINTEGRACAO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_126_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_127_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 127 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."EMPRESADEPOSITANTE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."EMPRESADEPOSITANTE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_127_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_128_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 128 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XFK_EDEPOSITANT_FINTEGR" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XFK_EDEPOSITANT_FINTEGR" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_128_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_129_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 129 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_EMPRESADEPOSITANTE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_EMPRESADEPOSITANTE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_129_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_130_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 130 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"EMPRESADEPOSITANTE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"EMPRESADEPOSITANTE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_130_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_131_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 131 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTOVOLUME" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTOVOLUME" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_131_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_132_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 132 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_DOCUMENTOVOLUME" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_DOCUMENTOVOLUME" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_132_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_133_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 133 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOVOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOVOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_133_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_134_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 134 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTOOCORRENCIA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTOOCORRENCIA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_134_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_135_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 135 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_DOCUMENTOOCORRENCIA" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_DOCUMENTOOCORRENCIA" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_135_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_136_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 136 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOOCORRENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOOCORRENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_136_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_137_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 137 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTOLOCALEMBALAGEMEXP" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTOLOCALEMBALAGEMEXP" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_137_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_138_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 138 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCUMENTOLOCALEMBALAGEMEXP" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCUMENTOLOCALEMBALAGEMEXP" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_138_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_139_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 139 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOLOCALEMBALAGEMEXP"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOLOCALEMBALAGEMEXP"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_139_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_140_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 140 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTOEMBALAGEM" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTOEMBALAGEM" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_140_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_141_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 141 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCUMENTOEMBALAGEM" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCUMENTOEMBALAGEM" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_141_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_142_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 142 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOEMBALAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTOEMBALAGEM"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_142_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_143_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 143 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTODETALHEVOLUME" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTODETALHEVOLUME" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_143_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_144_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 144 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCUMENTODETALHEVOLUME" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCUMENTODETALHEVOLUME" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_144_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_145_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 145 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHEVOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHEVOLUME"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_145_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_146_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 146 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTODETALHESERIE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTODETALHESERIE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_146_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_147_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 147 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."PK_DOCUMENTODETALHESERIE" REBUILD TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."PK_DOCUMENTODETALHESERIE" REBUILD TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_147_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_148_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 148 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHESERIE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHESERIE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_148_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_149_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 149 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTODETALHESEQUENCIA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTODETALHESEQUENCIA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_149_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_150_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 150 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCDETALHESEQUENCIA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCDETALHESEQUENCIA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_150_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_151_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 151 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHESEQUENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHESEQUENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_151_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_152_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 152 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTODETALHE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTODETALHE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_152_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_153_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 153 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCUMENTODETALHE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCUMENTODETALHE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_153_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_154_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 154 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTODETALHE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_154_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_155_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 155 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DOCUMENTO" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DOCUMENTO" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_155_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_156_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 156 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_DOCUMENTO_NDOCUMENTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_DOCUMENTO_NDOCUMENTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_156_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_157_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 157 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DOCUMENTO" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DOCUMENTO" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_157_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_158_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 158 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTO"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DOCUMENTO"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_158_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_159_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 159 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DEMANDAITEMSAIDA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DEMANDAITEMSAIDA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_159_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_160_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 160 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DEMANDAITEMSAIDA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DEMANDAITEMSAIDA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_160_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_161_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 161 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEMSAIDA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEMSAIDA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_161_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_162_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 162 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DEMANDAITEMENTRADA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DEMANDAITEMENTRADA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_162_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_163_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 163 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DEMANDAITEMENTRADA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DEMANDAITEMENTRADA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_163_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_164_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 164 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEMENTRADA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEMENTRADA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_164_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_165_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 165 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DEMANDAITEM" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DEMANDAITEM" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_165_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_166_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 166 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DEMANDAITEM" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DEMANDAITEM" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_166_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_167_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 167 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEM"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDAITEM"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_167_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_168_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 168 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."DEMANDA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."DEMANDA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_168_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_169_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 169 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_DEMANDA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_DEMANDA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_169_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_170_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 170 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"DEMANDA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_170_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_171_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 171 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."CONFERENCIA" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."CONFERENCIA" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_171_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_172_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 172 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_CONFERENCIA" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_CONFERENCIA" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_172_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_173_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 173 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"CONFERENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"CONFERENCIA"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_173_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_174_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 174 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLE "ORAINT"."CARGAESTOQUE" MOVE TABLESPACE "ORAINT_REORG0" ');
      EXECUTE IMMEDIATE 'ALTER TABLE "ORAINT"."CARGAESTOQUE" MOVE TABLESPACE "ORAINT_REORG0" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_174_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_175_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 175 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XAK_CARGAESTOQUE_DOC" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XAK_CARGAESTOQUE_DOC" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_175_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_176_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 176 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER INDEX "ORAINT"."XPK_CARGAESTOQUE" REBUILD TABLESPACE "ORAINTIND" ');
      EXECUTE IMMEDIATE 'ALTER INDEX "ORAINT"."XPK_CARGAESTOQUE" REBUILD TABLESPACE "ORAINTIND" ';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_176_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_177_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 177 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"CARGAESTOQUE"'', estimate_percent=>NULL, cascade=>TRUE); END;');
      EXECUTE IMMEDIATE 'BEGIN DBMS_STATS.GATHER_TABLE_STATS(''"ORAINT"'', ''"CARGAESTOQUE"'', estimate_percent=>NULL, cascade=>TRUE); END;';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_177_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_178_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 178 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_dropTbsp('"ORAINT"');
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_178_61;
/

CREATE OR REPLACE PROCEDURE mgmt$step_179_61(script_id IN INTEGER, job_table IN VARCHAR2, step_num IN OUT INTEGER)
AUTHID CURRENT_USER IS
    sqlerr_msg VARCHAR2(100);
BEGIN
    IF step_num <> 179 THEN
      return;
    END IF;

    mgmt$reorg_setStep (61, 'MGMT$REORG_CHECKPOINT', step_num);
    step_num := step_num + 1;
    BEGIN
      mgmt$reorg_sendMsg ('ALTER TABLESPACE "ORAINT_REORG0" RENAME TO "ORAINT"');
      EXECUTE IMMEDIATE 'ALTER TABLESPACE "ORAINT_REORG0" RENAME TO "ORAINT"';
    EXCEPTION
      WHEN OTHERS THEN
        sqlerr_msg := SUBSTR(SQLERRM, 1, 100);
        mgmt$reorg_errorExitOraError('ERRO ao executar as etapas ',  sqlerr_msg);
        step_num := -1;
        return;
    END;
END mgmt$step_179_61;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_cleanup_61 (script_id IN INTEGER, job_table IN VARCHAR2, step_num IN INTEGER, highest_step IN INTEGER)
AUTHID CURRENT_USER IS
BEGIN
    IF step_num <= highest_step THEN
      return;
    END IF;

    mgmt$reorg_sendMsg ('Iniciando limpeza de tabelas recuperadas');

    mgmt$reorg_deleteJobTableEntry(script_id, job_table, step_num, highest_step);

    mgmt$reorg_sendMsg ('Limpeza das tabelas de recuperação concluída');
END mgmt$reorg_cleanup_61;
/

CREATE OR REPLACE PROCEDURE mgmt$reorg_commentheader_61 IS
BEGIN
     mgmt$reorg_sendMsg ('--   Banco de dados de destino:	orcl');
     mgmt$reorg_sendMsg ('--   Script gerado às:	22-NOV-2015   21:10');
END mgmt$reorg_commentheader_61;
/

-- Controlador de Execução de Script
-- ==============================================

variable step_num number;
exec mgmt$reorg_commentheader_61;
exec mgmt$reorg_sendMsg ('Iniciando reorganização');
show user;
exec mgmt$reorg_checkDBAPrivs;
exec mgmt$reorg_setupJobTable (61, 'MGMT$REORG_CHECKPOINT', :step_num);

exec mgmt$step_1_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_2_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_3_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_4_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_5_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_6_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_7_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_8_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_9_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_10_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_11_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_12_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_13_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_14_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_15_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_16_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_17_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_18_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_19_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_20_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_21_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_22_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_23_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_24_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_25_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_26_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_27_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_28_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_29_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_30_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_31_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_32_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_33_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_34_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_35_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_36_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_37_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_38_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_39_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_40_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_41_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_42_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_43_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_44_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_45_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_46_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_47_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_48_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_49_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_50_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_51_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_52_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_53_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_54_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_55_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_56_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_57_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_58_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_59_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_60_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_61_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_62_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_63_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_64_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_65_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_66_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_67_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_68_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_69_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_70_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_71_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_72_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_73_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_74_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_75_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_76_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_77_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_78_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_79_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_80_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_81_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_82_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_83_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_84_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_85_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_86_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_87_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_88_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_89_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_90_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_91_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_92_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_93_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_94_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_95_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_96_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_97_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_98_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_99_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_100_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_101_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_102_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_103_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_104_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_105_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_106_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_107_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_108_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_109_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_110_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_111_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_112_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_113_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_114_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_115_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_116_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_117_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_118_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_119_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_120_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_121_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_122_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_123_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_124_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_125_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_126_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_127_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_128_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_129_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_130_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_131_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_132_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_133_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_134_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_135_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_136_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_137_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_138_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_139_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_140_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_141_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_142_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_143_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_144_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_145_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_146_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_147_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_148_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_149_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_150_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_151_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_152_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_153_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_154_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_155_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_156_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_157_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_158_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_159_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_160_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_161_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_162_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_163_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_164_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_165_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_166_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_167_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_168_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_169_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_170_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_171_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_172_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_173_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_174_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_175_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_176_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_177_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_178_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);
exec mgmt$step_179_61(61, 'MGMT$REORG_CHECKPOINT', :step_num);

exec mgmt$reorg_sendMsg ('Reorganização Concluída. Iniciando fase de limpeza.');

exec mgmt$reorg_cleanup_61 (61, 'MGMT$REORG_CHECKPOINT', :step_num, 179);

exec mgmt$reorg_sendMsg ('Iniciando limpeza de procedures gerados');

DROP PROCEDURE mgmt$step_1_61;
DROP PROCEDURE mgmt$step_2_61;
DROP PROCEDURE mgmt$step_3_61;
DROP PROCEDURE mgmt$step_4_61;
DROP PROCEDURE mgmt$step_5_61;
DROP PROCEDURE mgmt$step_6_61;
DROP PROCEDURE mgmt$step_7_61;
DROP PROCEDURE mgmt$step_8_61;
DROP PROCEDURE mgmt$step_9_61;
DROP PROCEDURE mgmt$step_10_61;
DROP PROCEDURE mgmt$step_11_61;
DROP PROCEDURE mgmt$step_12_61;
DROP PROCEDURE mgmt$step_13_61;
DROP PROCEDURE mgmt$step_14_61;
DROP PROCEDURE mgmt$step_15_61;
DROP PROCEDURE mgmt$step_16_61;
DROP PROCEDURE mgmt$step_17_61;
DROP PROCEDURE mgmt$step_18_61;
DROP PROCEDURE mgmt$step_19_61;
DROP PROCEDURE mgmt$step_20_61;
DROP PROCEDURE mgmt$step_21_61;
DROP PROCEDURE mgmt$step_22_61;
DROP PROCEDURE mgmt$step_23_61;
DROP PROCEDURE mgmt$step_24_61;
DROP PROCEDURE mgmt$step_25_61;
DROP PROCEDURE mgmt$step_26_61;
DROP PROCEDURE mgmt$step_27_61;
DROP PROCEDURE mgmt$step_28_61;
DROP PROCEDURE mgmt$step_29_61;
DROP PROCEDURE mgmt$step_30_61;
DROP PROCEDURE mgmt$step_31_61;
DROP PROCEDURE mgmt$step_32_61;
DROP PROCEDURE mgmt$step_33_61;
DROP PROCEDURE mgmt$step_34_61;
DROP PROCEDURE mgmt$step_35_61;
DROP PROCEDURE mgmt$step_36_61;
DROP PROCEDURE mgmt$step_37_61;
DROP PROCEDURE mgmt$step_38_61;
DROP PROCEDURE mgmt$step_39_61;
DROP PROCEDURE mgmt$step_40_61;
DROP PROCEDURE mgmt$step_41_61;
DROP PROCEDURE mgmt$step_42_61;
DROP PROCEDURE mgmt$step_43_61;
DROP PROCEDURE mgmt$step_44_61;
DROP PROCEDURE mgmt$step_45_61;
DROP PROCEDURE mgmt$step_46_61;
DROP PROCEDURE mgmt$step_47_61;
DROP PROCEDURE mgmt$step_48_61;
DROP PROCEDURE mgmt$step_49_61;
DROP PROCEDURE mgmt$step_50_61;
DROP PROCEDURE mgmt$step_51_61;
DROP PROCEDURE mgmt$step_52_61;
DROP PROCEDURE mgmt$step_53_61;
DROP PROCEDURE mgmt$step_54_61;
DROP PROCEDURE mgmt$step_55_61;
DROP PROCEDURE mgmt$step_56_61;
DROP PROCEDURE mgmt$step_57_61;
DROP PROCEDURE mgmt$step_58_61;
DROP PROCEDURE mgmt$step_59_61;
DROP PROCEDURE mgmt$step_60_61;
DROP PROCEDURE mgmt$step_61_61;
DROP PROCEDURE mgmt$step_62_61;
DROP PROCEDURE mgmt$step_63_61;
DROP PROCEDURE mgmt$step_64_61;
DROP PROCEDURE mgmt$step_65_61;
DROP PROCEDURE mgmt$step_66_61;
DROP PROCEDURE mgmt$step_67_61;
DROP PROCEDURE mgmt$step_68_61;
DROP PROCEDURE mgmt$step_69_61;
DROP PROCEDURE mgmt$step_70_61;
DROP PROCEDURE mgmt$step_71_61;
DROP PROCEDURE mgmt$step_72_61;
DROP PROCEDURE mgmt$step_73_61;
DROP PROCEDURE mgmt$step_74_61;
DROP PROCEDURE mgmt$step_75_61;
DROP PROCEDURE mgmt$step_76_61;
DROP PROCEDURE mgmt$step_77_61;
DROP PROCEDURE mgmt$step_78_61;
DROP PROCEDURE mgmt$step_79_61;
DROP PROCEDURE mgmt$step_80_61;
DROP PROCEDURE mgmt$step_81_61;
DROP PROCEDURE mgmt$step_82_61;
DROP PROCEDURE mgmt$step_83_61;
DROP PROCEDURE mgmt$step_84_61;
DROP PROCEDURE mgmt$step_85_61;
DROP PROCEDURE mgmt$step_86_61;
DROP PROCEDURE mgmt$step_87_61;
DROP PROCEDURE mgmt$step_88_61;
DROP PROCEDURE mgmt$step_89_61;
DROP PROCEDURE mgmt$step_90_61;
DROP PROCEDURE mgmt$step_91_61;
DROP PROCEDURE mgmt$step_92_61;
DROP PROCEDURE mgmt$step_93_61;
DROP PROCEDURE mgmt$step_94_61;
DROP PROCEDURE mgmt$step_95_61;
DROP PROCEDURE mgmt$step_96_61;
DROP PROCEDURE mgmt$step_97_61;
DROP PROCEDURE mgmt$step_98_61;
DROP PROCEDURE mgmt$step_99_61;
DROP PROCEDURE mgmt$step_100_61;
DROP PROCEDURE mgmt$step_101_61;
DROP PROCEDURE mgmt$step_102_61;
DROP PROCEDURE mgmt$step_103_61;
DROP PROCEDURE mgmt$step_104_61;
DROP PROCEDURE mgmt$step_105_61;
DROP PROCEDURE mgmt$step_106_61;
DROP PROCEDURE mgmt$step_107_61;
DROP PROCEDURE mgmt$step_108_61;
DROP PROCEDURE mgmt$step_109_61;
DROP PROCEDURE mgmt$step_110_61;
DROP PROCEDURE mgmt$step_111_61;
DROP PROCEDURE mgmt$step_112_61;
DROP PROCEDURE mgmt$step_113_61;
DROP PROCEDURE mgmt$step_114_61;
DROP PROCEDURE mgmt$step_115_61;
DROP PROCEDURE mgmt$step_116_61;
DROP PROCEDURE mgmt$step_117_61;
DROP PROCEDURE mgmt$step_118_61;
DROP PROCEDURE mgmt$step_119_61;
DROP PROCEDURE mgmt$step_120_61;
DROP PROCEDURE mgmt$step_121_61;
DROP PROCEDURE mgmt$step_122_61;
DROP PROCEDURE mgmt$step_123_61;
DROP PROCEDURE mgmt$step_124_61;
DROP PROCEDURE mgmt$step_125_61;
DROP PROCEDURE mgmt$step_126_61;
DROP PROCEDURE mgmt$step_127_61;
DROP PROCEDURE mgmt$step_128_61;
DROP PROCEDURE mgmt$step_129_61;
DROP PROCEDURE mgmt$step_130_61;
DROP PROCEDURE mgmt$step_131_61;
DROP PROCEDURE mgmt$step_132_61;
DROP PROCEDURE mgmt$step_133_61;
DROP PROCEDURE mgmt$step_134_61;
DROP PROCEDURE mgmt$step_135_61;
DROP PROCEDURE mgmt$step_136_61;
DROP PROCEDURE mgmt$step_137_61;
DROP PROCEDURE mgmt$step_138_61;
DROP PROCEDURE mgmt$step_139_61;
DROP PROCEDURE mgmt$step_140_61;
DROP PROCEDURE mgmt$step_141_61;
DROP PROCEDURE mgmt$step_142_61;
DROP PROCEDURE mgmt$step_143_61;
DROP PROCEDURE mgmt$step_144_61;
DROP PROCEDURE mgmt$step_145_61;
DROP PROCEDURE mgmt$step_146_61;
DROP PROCEDURE mgmt$step_147_61;
DROP PROCEDURE mgmt$step_148_61;
DROP PROCEDURE mgmt$step_149_61;
DROP PROCEDURE mgmt$step_150_61;
DROP PROCEDURE mgmt$step_151_61;
DROP PROCEDURE mgmt$step_152_61;
DROP PROCEDURE mgmt$step_153_61;
DROP PROCEDURE mgmt$step_154_61;
DROP PROCEDURE mgmt$step_155_61;
DROP PROCEDURE mgmt$step_156_61;
DROP PROCEDURE mgmt$step_157_61;
DROP PROCEDURE mgmt$step_158_61;
DROP PROCEDURE mgmt$step_159_61;
DROP PROCEDURE mgmt$step_160_61;
DROP PROCEDURE mgmt$step_161_61;
DROP PROCEDURE mgmt$step_162_61;
DROP PROCEDURE mgmt$step_163_61;
DROP PROCEDURE mgmt$step_164_61;
DROP PROCEDURE mgmt$step_165_61;
DROP PROCEDURE mgmt$step_166_61;
DROP PROCEDURE mgmt$step_167_61;
DROP PROCEDURE mgmt$step_168_61;
DROP PROCEDURE mgmt$step_169_61;
DROP PROCEDURE mgmt$step_170_61;
DROP PROCEDURE mgmt$step_171_61;
DROP PROCEDURE mgmt$step_172_61;
DROP PROCEDURE mgmt$step_173_61;
DROP PROCEDURE mgmt$step_174_61;
DROP PROCEDURE mgmt$step_175_61;
DROP PROCEDURE mgmt$step_176_61;
DROP PROCEDURE mgmt$step_177_61;
DROP PROCEDURE mgmt$step_178_61;
DROP PROCEDURE mgmt$step_179_61;

DROP PROCEDURE mgmt$reorg_cleanup_61;
DROP PROCEDURE mgmt$reorg_commentheader_61;

exec mgmt$reorg_sendMsg ('Limpeza dos procedures gerados concluída');

exec mgmt$reorg_sendMsg ('Execução de script concluída');

spool off
set pagesize 24
set serveroutput off
set feedback on
set echo on
set ver on
