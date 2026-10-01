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
--
-- Verificado contra producción: aun así el EXECUTE concedido a `PUBLIC`
-- sigue activo y NO es un hueco. `select public.handle_new_user();`
-- responde SQLSTATE 0A000 "trigger functions can only be called as
-- triggers", y PostgREST ni siquiera la publica (HTTP 404). No se revoca
-- de `PUBLIC` a propósito: arriesgaría el disparador que crea el perfil
-- durante el registro de usuarios.
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
   6. BLOQUEO DE PAGO — `plan_status` ya no lo toca el usuario

   La política "own profile" es `for all`, así que cualquiera que
   inicie sesión se podía marcar la suscripción como activa:

       update public.profiles set plan_status='active';

   Se verificó contra producción: el rol `authenticated` SÍ tenía
   ese privilegio. Ahora se revoca el UPDATE de la tabla entera y se
   devuelve únicamente por columna sobre las dos que la app necesita:

       full_name  →  nombre de la óptica ("Mi óptica")
       logo_path  →  logo de la óptica (bucket privado `branding`)

   `plan_status` y `plan_next_charge` quedan reservados: se cambian
   desde el Dashboard de Supabase o, cuando exista, desde el webhook
   de una pasarela de pago real.

   Consecuencia deliberada: los botones "Simular pago exitoso",
   "Simular pago vencido" y "Pagar ahora" se retiraron de la app,
   porque ya no podrían persistir el cambio y habrían mentido en la
   pantalla. El INSERT del registro nuevo lo sigue haciendo
   handle_new_user() (SECURITY DEFINER), que corre con los
   privilegios del propietario de la función.
   ============================================================ */
revoke update on public.profiles from authenticated;
grant  update (full_name, logo_path) on public.profiles to authenticated;

/* ------------------------------------------------------------
   6b. VERIFICACIÓN — el aviso debe decir "TODO OK"
   ------------------------------------------------------------ */
do $$
declare bad text := '';
begin
  if not has_column_privilege('authenticated','public.profiles','full_name','UPDATE')        then bad := bad || 'full_name-bloqueado ';        end if;
  if not has_column_privilege('authenticated','public.profiles','logo_path','UPDATE')        then bad := bad || 'logo_path-bloqueado ';        end if;
  if     has_column_privilege('authenticated','public.profiles','plan_status','UPDATE')      then bad := bad || 'plan_status-editable ';       end if;
  if     has_column_privilege('authenticated','public.profiles','plan_next_charge','UPDATE') then bad := bad || 'plan_next_charge-editable ';  end if;
  if has_table_privilege('anon','public.profiles','UPDATE')                                 then bad := bad || 'anon-profiles-update ';       end if;

  raise notice '%', case when bad='' then 'TODO OK: plan_status cerrado' else 'REVISAR: '||bad end;
end $$;
