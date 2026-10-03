/* ============================================================
   Optiluxen — PAGOS (Mercado Pago) + CIERRE DEL HUECO DE profiles
   Ejecutar en: Dashboard → SQL Editor → New query → Run
   Es idempotente: puedes ejecutarlo cuantas veces quieras.

   HALLAZGO VERIFICADO CONTRA LA BASE EN PRODUCCIÓN
   ------------------------------------------------
   La política "own profile" es cmd=ALL, así que incluía DELETE, y el
   privilegio estaba concedido a nivel de tabla. Comprobado con un
   usuario real:

       DELETE /rest/v1/profiles?id=eq.<yo>          → 204
       POST   /rest/v1/profiles {plan_status:'active',
                                 plan_next_charge:'2099-12-31'}  → 201
       → [{"plan_status":"active","plan_next_charge":"2099-12-31"}]

   Es decir: cualquiera podía borrarse su fila y volver a insertarla
   PAGADA. Cerrado aquí con tres llaves:
     · DELETE revocado            → ya no puede borrar su fila
     · INSERT por columnas        → ni plan_status ni plan_next_charge
     · UPDATE sigue por columnas  → como en el bloque 6

   El registro NO se toca: public.handle_new_user() es SECURITY DEFINER
   con owner postgres (prosecdef = true), así que inserta plan_status y
   plan_next_charge con sus propios privilegios, no con los del usuario.
   ============================================================ */

/* ------------------------------------------------------------
   1. Columna nueva: la suscripción de Mercado Pago del usuario.
   Solo la escribe la Edge Function (service role) y, de forma
   inocua, el propio usuario. Nada de esto toca plan_status.
   ------------------------------------------------------------ */
alter table public.profiles add column if not exists mp_preapproval_id text;

/* ------------------------------------------------------------
   2. UPDATE → solo columnas de identidad/adjuntos.
   (el UPDATE de tabla entera ya estaba revocado en el bloque 6;
   se repite para que este archivo también sirva solo)
   ------------------------------------------------------------ */
revoke update on public.profiles from authenticated;
revoke update (id, full_name, plan_status, plan_next_charge,
               created_at, logo_path, mp_preapproval_id)
  on public.profiles from authenticated;
grant  update (full_name, logo_path, mp_preapproval_id)
  on public.profiles to authenticated;

/* ------------------------------------------------------------
   3. DELETE → revocado. La fila se elimina cuando se elimina el
   usuario (ON DELETE CASCADE desde auth.users), operación del
   administrador; la app nunca borra perfiles.
   ------------------------------------------------------------ */
revoke delete on public.profiles from authenticated;

/* ------------------------------------------------------------
   4. INSERT → por columnas, sin las columnas del plan.
   Se necesita insertar solo en el respaldo de patchPerfil()
   (cuentas muy antiguas sin fila). El registro va por el trigger
   SECURITY DEFINER, que no depende de estos privilegios.
   ------------------------------------------------------------ */
revoke insert on public.profiles from authenticated;
revoke insert (id, full_name, plan_status, plan_next_charge,
               created_at, logo_path, mp_preapproval_id)
  on public.profiles from authenticated;
grant  insert (id, full_name, logo_path, mp_preapproval_id)
  on public.profiles to authenticated;

/* ------------------------------------------------------------
   5. VERIFICACIÓN — se detiene con "REVISAR -> …" si algo falla.
   ------------------------------------------------------------ */
do $$
declare bad text := '';
begin
  if has_table_privilege('authenticated', 'public.profiles', 'DELETE')
    then bad := bad || 'DELETE-sigue-permitido ';                         end if;

  if has_column_privilege('authenticated', 'public.profiles', 'plan_status', 'UPDATE')
    then bad := bad || 'update-plan_status ';                            end if;
  if has_column_privilege('authenticated', 'public.profiles', 'plan_next_charge', 'UPDATE')
    then bad := bad || 'update-plan_next_charge ';                       end if;
  if has_column_privilege('authenticated', 'public.profiles', 'plan_status', 'INSERT')
    then bad := bad || 'insert-plan_status ';                            end if;
  if has_column_privilege('authenticated', 'public.profiles', 'plan_next_charge', 'INSERT')
    then bad := bad || 'insert-plan_next_charge ';                       end if;

  if not has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE')
    then bad := bad || 'full_name-update-bloqueado ';                    end if;
  if not has_column_privilege('authenticated', 'public.profiles', 'logo_path', 'UPDATE')
    then bad := bad || 'logo_path-update-bloqueado ';                    end if;
  if not has_column_privilege('authenticated', 'public.profiles', 'mp_preapproval_id', 'UPDATE')
    then bad := bad || 'mp_preapproval_id-update-bloqueado ';            end if;
  if not has_column_privilege('authenticated', 'public.profiles', 'id', 'INSERT')
    then bad := bad || 'id-insert-bloqueado ';                           end if;

  raise notice '%', case when bad = '' then 'OK: hueco cerrado y columnas en orden'
                         else 'REVISAR -> ' || bad end;
end $$;
