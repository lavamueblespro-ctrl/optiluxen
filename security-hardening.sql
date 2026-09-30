/* ============================================================
   Optiluxen — ENDURECIMIENTO DE SEGURIDAD
   Ejecutar en: Dashboard → SQL Editor → New query → Run
   Es idempotente: puedes ejecutarlo cuantas veces quieras.

   Se ejecutó primero una auditoría real contra la base en producción:
   RLS estaba activo en las 8 tablas, pero esto NO estaba aplicado.
   ============================================================ */

/* ------------------------------------------------------------
   1. EL ROL `anon` NO TOCA LA BASE DE DATOS

   `anon` es el rol que usa la clave pública (anon key) que vive en
   config.js. Esa clave es visible por definición para cualquiera que
   abra las herramientas de desarrollo, así que el trabajo sucio lo
   tiene que hacer RLS.

   En la app NINGUNA consulta corre sin sesión: `loadAll()` y todo el
   resto se ejecutan dentro de `enterApp()`, después del login. Luego
   `anon` no necesita ni un privilegio.
   ------------------------------------------------------------ */
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

/* ------------------------------------------------------------
   2. TRUNCATE NO ESTÁ CUBIERTO POR RLS  ← hallazgo verificado

   Se comprobó contra la base real: con una política que negaba TODO
   al rol `anon`, un `TRUNCATE` ejecutado como `anon` igual vació la
   tabla de prueba (DELETE sí quedó bloqueado).

   PostgREST no expone TRUNCATE, así que hoy no hay ruta de ataque
   desde la web; pero el privilegio no debe existir. Se revoca el
   TRUNCATE (y REFERENCES/TRIGGER) manteniendo select/insert/update/
   delete, que RLS sí filtra fila por fila.
   ------------------------------------------------------------ */
revoke truncate, references, trigger
  on all tables in schema public from anon, authenticated;

/* ------------------------------------------------------------
   3. FUNCIONES: nadie ejecuta las funciones de sistema a mano
   ------------------------------------------------------------ */
-- handle_new_user() es la función disparadora que crea el perfil al
-- registrarse. PostgreSQL se niega a invocar funciones disparadoras
-- directamente, y el rol `anon`/`authenticated` jamás inserta en
-- auth.users, así que se le quita el EXECUTE.
revoke execute on function public.handle_new_user() from anon, authenticated;

/* ------------------------------------------------------------
   4. CONTADOR DE FACTURAS: solo por la función oficial

   La política "own counters" era `for all`, lo que permitía a cualquier
   usuario editar su propio `invoice_seq` y reutilizar/filtrar números
   de factura. Los números se emiten únicamente con next_invoice_no()
   (SECURITY DEFINER, ya revocada a `anon`), así que UPDATE sobra.
   ------------------------------------------------------------ */
revoke update on public.counters from anon, authenticated;
grant  select on public.counters to authenticated;

/* ------------------------------------------------------------
   5. VERIFICACIÓN — debería devolver todo en 'OK'
   ------------------------------------------------------------ */
do $$
declare t text; bad text := '';
begin
  foreach t in array array['profiles','clients','prescriptions','sales',
                           'sale_items','reminder_settings','reminder_log','counters']
  loop
    if has_table_privilege('anon', 'public.'||t, 'SELECT')   then bad := bad||t||':anon-select ';   end if;
    if has_table_privilege('anon', 'public.'||t, 'INSERT')   then bad := bad||t||':anon-insert ';   end if;
    if has_table_privilege('anon', 'public.'||t, 'TRUNCATE') then bad := bad||t||':anon-truncate '; end if;
    if has_table_privilege('authenticated', 'public.'||t, 'TRUNCATE') then bad := bad||t||':auth-truncate '; end if;
    if has_table_privilege('authenticated', 'public.'||t, 'TRIGGER')  then bad := bad||t||':auth-trigger ';  end if;
  end loop;

  if exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relkind='r' and not c.relrowsecurity)
  then bad := bad || 'tabla-sin-rls '; end if;

  if has_table_privilege('authenticated','public.counters','UPDATE')
     and has_column_privilege('authenticated','public.counters','invoice_seq','UPDATE')
  then bad := bad || 'counters-editable '; end if;

  raise notice '%', case when bad='' then 'TODO OK: endurecimiento aplicado' else 'REVISAR: '||bad end;
end $$;

/* ============================================================
   6. DECISIÓN PENDIENTE — BLOQUEO DE PAGO  (dejado comentado a propósito)

   La política "own profile" es `for all`, así que cualquiera que inicie
   sesión puede hacerse la vida eterna con:

       update public.profiles set plan_status='active';

   Se verificó: el rol autenticado SÍ tiene ese permiso. Es la misma
   llamada que usa el botón "Simular pago exitoso" de la app.

   Si lo activas, el botón "Pagar ahora" dejará de funcionar (habría que
   conectar una pasarela de pago real con webhook). Descomenta para
   cerrar el agujero:

revoke update (full_name, logo_path) on public.profiles from authenticated;
grant  update (full_name, logo_path) on public.profiles to authenticated;

   Nota: `logo_path` y `full_name` siguen editables; plan_status y
   plan_next_charge quedan reservados. El INSERT del registro nuevo lo
   sigue haciendo la función handle_new_user() (SECURITY DEFINER).
   ============================================================ */
