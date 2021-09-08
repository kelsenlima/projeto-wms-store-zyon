select * from texto1 for update

select *
from ua ua, texto1 t1
where ua.codigoua = t1.texto04
and ua.utilizado = 0

UPDATE UA UA
   SET UA.ENDERECO = (SELECT T1.TEXTO01 FROM TEXTO1 T1 WHERE T1.TEXTO04 = UA.CODIGOUA),
   UA.TIPOUA = 2,
   UA.ENDERECOFIXO = (SELECT T1.TEXTO01 FROM TEXTO1 T1 WHERE T1.TEXTO04 = UA.CODIGOUA),
   UA.UTILIZADO = 1
 WHERE EXISTS (SELECT T1.TEXTO04 FROM TEXTO1 T1 WHERE T1.TEXTO04 = UA.CODIGOUA)

UPDATE ENDERECO E
   SET E.ESPECIEENDERECO=17
 WHERE E.ETIQUETAENDERECO IN (SELECT TEXTO FROM TEXTO1)
 
UPDATE suppliers
SET supplier_name = (SELECT customers.customer_name
                     FROM customers
                     WHERE customers.customer_id = suppliers.supplier_id)
WHERE EXISTS (SELECT customers.customer_name
              FROM customers
              WHERE customers.customer_id = suppliers.supplier_id);
