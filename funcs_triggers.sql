-- 1. Функция создания бронирования
create or replace function create_booking(
    p_guest_id int,
    p_room_id int,
    p_check_in date,
    p_check_out date
)
returns int as $$
declare
    v_booking_id int;
    v_price numeric(10,2);
    v_next_id int;
    v_room_exists boolean;
    v_guest_exists boolean;
    v_conflict_count int;
    v_capacity int;
    v_room_type_id int;
    v_available_rooms_count int;
begin
    -- Проверка корректности дат
    if p_check_out <= p_check_in then
        raise exception 'Дата выезда должна быть позже даты заезда';
    end if;

    -- Проверка существования гостя
    select exists(select 1 from guests where id = p_guest_id) into v_guest_exists;
    if not v_guest_exists then
        raise exception 'Гость с ID % не найден', p_guest_id;
    end if;

    -- ЗАЩИТА ОТ Race condition
    select exists(select 1 from rooms where id = p_room_id for update) into v_room_exists;
    if not v_room_exists then
        raise exception 'Комната с ID % не найдена', p_room_id;
    end if;

    -- Получение типа комнаты
    select room_type_id into v_room_type_id from rooms where id = p_room_id;

    -- Подсчет количества доступных комнат на эти даты
    select count(*) into v_available_rooms_count
    from rooms r
    where r.room_type_id = v_room_type_id
      and r.is_available = true
      and not exists (
          select 1 from bookings b
          where b.room_id = r.id
            and b.status in ('confirmed', 'pending')
            and tsrange(b.check_in, b.check_out, '[]') && tsrange(p_check_in, p_check_out, '[]')
      );

    -- Если комната или подобные заняты
    select count(*) into v_conflict_count
    from bookings 
    where room_id = p_room_id
        and status in ('confirmed', 'pending')
        and tsrange(check_in, check_out, '[]') && tsrange(p_check_in, p_check_out, '[]');

    if v_conflict_count > 0 or v_available_rooms_count = 0 then
        raise exception 'Комната уже забронирована на указанные даты (Доступно комнат этого типа: %)', v_available_rooms_count;
    end if;

    -- Получение стоимости проживания
    select base_price into v_price 
    from room_types 
    where id = v_room_type_id;

    -- Генерация уникального ID из системного счетчика
    v_next_id := nextval('bookings_id_seq');

    -- Вставка записи бронирования
    insert into bookings (id, check_in, guest_id, room_id, check_out, status, price_at_booking)
    values (v_next_id, p_check_in, p_guest_id, p_room_id, p_check_out, 'pending', v_price)
    returning id into v_booking_id;

    return v_booking_id;
end;
$$ language plpgsql;

-- 2. Функция отмены бронирования (С штрафом)
create or replace function cancel_booking(
    p_booking_id int
)
returns table(
    booking_id int,
    status_before varchar,
    status_after varchar,
    penalty numeric(10,2)
) as $$
declare
    v_check_in date;
    v_hours_before int;
    v_price numeric(10,2);
    v_penalty numeric(10,2) := 0;
    v_status varchar(20);
begin
    select check_in, price_at_booking, status
    into v_check_in, v_price, v_status
    from bookings
    where id = p_booking_id;

    if not found then
        raise exception 'Бронирование с ID % не найдено', p_booking_id;
    end if;

    if v_status = 'cancelled' then
        raise exception 'Бронирование уже отменено';
    end if;

    -- Вычисление количества часов до заселения
    v_hours_before := extract(epoch from (v_check_in - now())) / 3600;

    -- Штраф 50% от стоимости, если до заселения осталось меньше суток
    if v_hours_before < 24 and v_hours_before > 0 then
        v_penalty := v_price * 0.5;
    end if;

    update bookings 
    set status = 'cancelled' 
    where id = p_booking_id;

    return query
    select p_booking_id, v_status, 'cancelled'::varchar, v_penalty;
end;
$$ language plpgsql;


-- 3. Функция подтверждения бронирования менеджером отеля
create or replace function confirm_booking(
    p_booking_id int
)
returns boolean as $$
declare
    v_status varchar(20);
begin
    select status into v_status from bookings where id = p_booking_id;

    if not found then
        raise exception 'Бронирование с ID % не найдено', p_booking_id;
    end if;

    if v_status = 'confirmed' then 
        return true; 
    end if;
    
    if v_status = 'cancelled' then 
        raise exception 'Нельзя подтвердить отмененную бронь'; 
    end if;

    update bookings set status = 'confirmed' where id = p_booking_id;
    return true;
end;
$$ language plpgsql;


-- 4. Поиск номеров по параметрам
create or replace function find_available_rooms(
    p_hotel_id int,
    p_check_in date,
    p_check_out date,
    p_capacity int default null
)
returns table(
    room_id int,
    room_number varchar,
    room_type_name varchar,
    price numeric(10,2),
    capacity int
) as $$
begin
    return query
    select 
        r.id, r.room_number, rt.name, rt.base_price, rt.capacity
    from rooms r
    join room_types rt on r.room_type_id = rt.id
    join hotels h on rt.hotel_id = h.id
    where h.id = p_hotel_id
        and r.is_available = true
        and not exists (
            select 1 from bookings b
            where b.room_id = r.id
                and b.status in ('confirmed', 'pending')
                and tsrange(b.check_in, b.check_out, '[]') && tsrange(p_check_in, p_check_out, '[]')
        )
        and (p_capacity is null or rt.capacity >= p_capacity)
    order by rt.base_price;
end;
$$ language plpgsql;


-- 5. Автоматическое обновление доступности номеров
create or replace function update_room_availability()
returns trigger as $$
declare
    v_room_id int;
    v_should_be_available boolean;
    v_current_available boolean;
begin
    if tg_op = 'INSERT' or tg_op = 'UPDATE' then
        v_room_id := new.room_id;
    elsif tg_op = 'DELETE' then
        v_room_id := old.room_id;
    end if;

    -- Проверка занятости номера
    if exists (
        select 1 from bookings 
        where room_id = v_room_id 
          and status in ('confirmed', 'pending')
          and current_date between check_in and check_out
    ) then
        v_should_be_available := false;
    else
        v_should_be_available := true;
    end if;

    select is_available into v_current_available from rooms where id = v_room_id;

    -- Обновление статуса комнаты
    if v_current_available is distinct from v_should_be_available then
        update rooms set is_available = v_should_be_available where id = v_room_id;
    end if;

    return null;
end;
$$ language plpgsql;

-- Триггер денормализации
create or replace trigger trg_room_availability
after insert or update or delete on bookings
for each row
execute function update_room_availability();


-- 6. Логика триггера аудита изменений статуса бронирований
create or replace function audit_booking_status_change()
returns trigger as $$
begin
    if tg_op = 'UPDATE' and old.status is distinct from new.status then
        insert into audit_log (table_name, operation, old_value, new_value, changed_by)
        values (
            'bookings',
            'UPDATE_STATUS',
            jsonb_build_object('id', old.id, 'status', old.status),
            jsonb_build_object('id', new.id, 'status', new.status, 'room_id', new.room_id),
            current_user
        );
    end if;
    return new;
end;
$$ language plpgsql;

-- Триггер аудита бронирований
create or replace trigger trg_audit_booking_status 
before update on bookings 
for each row 
execute function audit_booking_status_change();


-- 7. Логика триггера аудита цен и ведения истории стоимости номеров
create or replace function audit_price_change()
returns trigger as $$
begin
    if tg_op = 'UPDATE' and old.base_price is distinct from new.base_price then
        -- Запись в историческую таблицу цен
        insert into price_history (room_type_id, old_price, new_price)
        values (old.id, old.base_price, new.base_price);

        -- Запись в общий лог аудита
        insert into audit_log (table_name, operation, old_value, new_value, changed_by)
        values (
            'room_types',
            'UPDATE_PRICE',
            jsonb_build_object('id', old.id, 'price', old.base_price),
            jsonb_build_object('id', new.id, 'price', new.base_price),
            current_user
        );
    end if;
    return new;
end;
$$ language plpgsql;

-- Триггер денормализации
create or replace trigger trg_audit_price_change 
before update on room_types 
for each row 
execute function audit_price_change();