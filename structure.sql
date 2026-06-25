-- роли пользователей
create type user_role as enum ('guest', 'operator', 'admin');

-- расширение для работы с диапазонами дат
create extension if not exists btree_gist;


-- Таблица пользователей
create table users (
    id serial primary key,
    name varchar(100) not null,
    email varchar(100) unique not null,
    role user_role not null default 'guest'
);

-- Отели
create table hotels (
    id serial primary key,
    name varchar(150) not null,
    city varchar(100) not null,
    rating numeric(2, 1) check (rating >= 0.0 and rating <= 5.0),
    operator_id int references users(id) on delete set null
);

-- Типы номеров и базовая цена
create table room_types (
    id serial primary key,
    hotel_id int references hotels(id) on delete cascade,
    name varchar(100) not null,
    base_price numeric(10, 2) not null check (base_price > 0),
    capacity int not null check (capacity > 0)
);

-- Конкретные комнаты
create table rooms (
    id serial primary key,
    room_number varchar(10) not null,
    room_type_id int references room_types(id) on delete cascade,
    is_available boolean not null default true
);

-- Справочник удобств
create table amenities (
    id serial primary key,
    name varchar(100) unique not null
);

-- Связь многие-ко-многим (комнаты и удобства)
create table room_amenities (
    room_type_id int references room_types(id) on delete cascade,
    amenity_id int references amenities(id) on delete cascade,
    primary key (room_type_id, amenity_id)
);


-- Бронирования (таблица секционирована по дате заезда)
create table bookings (
    id int not null,
    check_in date not null,
    guest_id int references users(id) on delete cascade,
    room_id int references rooms(id) on delete cascade,
    check_out date not null,
    status varchar(20) not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled')),
    price_at_booking numeric(10, 2) not null check (price_at_booking >= 0),
    primary key (id, check_in), 
    constraint check_dates check (check_out > check_in)
) partition by range (check_in);

-- Секции на лето 2026
create table bookings_y2026m06 partition of bookings for values from ('2026-06-01') to ('2026-07-01');
create table bookings_y2026m07 partition of bookings for values from ('2026-07-01') to ('2026-08-01');
create table bookings_y2026m08 partition of bookings for values from ('2026-08-01') to ('2026-09-01');

-- Дефолтная секция
create table bookings_default partition of bookings default;


-- Платежи
create table payments (
    id serial primary key,
    booking_id int not null,
    amount numeric(10, 2) not null check (amount >= 0),
    status varchar(20) not null default 'pending' check (status in ('pending', 'paid', 'failed', 'refunded')),
    method varchar(20) not null check (method in ('card', 'cash'))
);

-- Отзывы
create table reviews (
    id serial primary key,
    booking_id int not null,
    rating int not null check (rating >= 1 and rating <= 5),
    comment text
);

-- История изменения цен
create table price_history (
    id serial primary key,
    room_type_id int references room_types(id) on delete cascade,
    old_price numeric(10, 2),
    new_price numeric(10, 2) not null,
    changed_at timestamp not null default now()
);

-- Лог изменений для триггеров (без внешних связей)
create table audit_log (
    id bigserial primary key,
    table_name varchar(50) not null,
    operation varchar(20) not null,
    old_value jsonb,
    new_value jsonb,
    changed_by varchar(100) not null default current_user,
    changed_at timestamp not null default now()
);


-- Базовые индексы для оптимизации
create index idx_u_email on users(email);
create index idx_h_city on hotels(city);
create index idx_r_type on rooms(room_type_id);
create index idx_b_guest on bookings(guest_id);