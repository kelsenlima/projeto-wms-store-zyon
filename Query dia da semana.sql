select to_char(sysdate, 'd') from dual;

T
-
2

select case when to_char(to_date('21/06/2014'), 'd') in (1,7) then 'FIM DE SEMANA'
           else 'DIA UTIL'
            end
     from dual;

CASEWHENTO_CH
-------------
DIA UTIL

select case when to_char(sysdate+5, 'd') in (1,7) then 'FIM DE SEMANA'
              else 'DIA UTIL'
         end
  from dual;

CASEWHENTO_CH
-------------
FIM DE SEMANA

SELECT TO_CHAR(DT_NASC,'"Brasília" DD "de" Month" de "YYYY','NLS_DATE_LANGUAGE=PORTUGUESE' )
FROM dual

SELECT TO_CHAR( SYSDATE , 'Month' , 'NLS_DATE_LANGUAGE=PORTUGUESE' )
  FROM DUAL
