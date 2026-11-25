import asyncio
import os
import hmac
import logging
import aiosqlite

from aiohttp import web
from aiogram import Bot, Dispatcher, F
from aiogram.filters import CommandStart, Command
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.context import FSMContext
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message,
    CallbackQuery,
    Update,
    InlineKeyboardMarkup,
    InlineKeyboardButton
)

logging.basicConfig(level=logging.INFO)

BOT_TOKEN = os.getenv("BOT_TOKEN")
ADMIN_ID = os.getenv("ADMIN_ID")
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET")
BASE_URL = os.getenv("RENDER_EXTERNAL_URL")
PORT = int(os.getenv("PORT", "10000"))

if not BOT_TOKEN:
    raise RuntimeError("Не задан BOT_TOKEN")

if not WEBHOOK_SECRET:
    raise RuntimeError("Не задан WEBHOOK_SECRET")

if not BASE_URL:
    raise RuntimeError("Не найден адрес Render")

DB_NAME = "domovoy.db"

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())


class Booking(StatesGroup):
    name = State()
    dates = State()
    guests = State()
    phone = State()


def main_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="🏡 Наши домики", callback_data="houses")],
        [InlineKeyboardButton(
            text="💰 Цены и условия", callback_data="prices")],
        [InlineKeyboardButton(
            text="📅 Забронировать", callback_data="booking")],
        [InlineKeyboardButton(
            text="🗝 Инструкция по заселению", callback_data="checkin")],
        [InlineKeyboardButton(
            text="👨‍💼 Администратор", callback_data="admin")]
    ])


async def init_db():
    async with aiosqlite.connect(DB_NAME) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS bookings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                telegram_id INTEGER,
                name TEXT,
                dates TEXT,
                guests TEXT,
                phone TEXT
            )
        """)
        await db.commit()


@dp.message(CommandStart())
async def start(message: Message, state: FSMContext):
    await state.clear()
    await message.answer(
        "Здравствуйте! 👋\n\n"
        "Я Домовой — виртуальный администратор нашей базы отдыха.\n"
        "Помогу выбрать домик, оставить заявку и разобраться "
        "с заселением.\n\n"
        "Чем могу помочь?",
        reply_markup=main_menu()
    )


@dp.message(Command("myid"))
async def my_id(message: Message):
    await message.answer(
        f"Ваш Telegram ID: {message.from_user.id}"
    )


@dp.message(Command("cancel"))
async def cancel(message: Message, state: FSMContext):
    await state.clear()
    await message.answer(
        "Действие отменено.",
        reply_markup=main_menu()
    )


@dp.callback_query(F.data == "houses")
async def houses(callback: CallbackQuery):
    await callback.message.answer(
        "🏡 Добро пожаловать!\n\n"
        "Напишите администратору, чтобы узнать "
        "подробнее о домиках.",
        reply_markup=main_menu()
    )
    await callback.answer()


@dp.callback_query(F.data == "prices")
async def prices(callback: CallbackQuery):
    await callback.message.answer(
        "💰 Стоимость зависит от выбранного домика, "
        "дат и количества гостей.\n\n"
        "Оставьте заявку, и администратор уточнит цену.",
        reply_markup=main_menu()
    )
    await callback.answer()


@dp.callback_query(F.data == "checkin")
async def checkin(callback: CallbackQuery):
    await callback.message.answer(
        "🗝 Инструкция по заселению отправляется "
        "после подтверждения бронирования.\n\n"
        "Вы получите адрес, маршрут, время заезда "
        "и порядок получения ключей.",
        reply_markup=main_menu()
    )
    await callback.answer()


@dp.callback_query(F.data == "booking")
async def booking_start(
    callback: CallbackQuery,
    state: FSMContext
):
    await state.clear()
    await state.set_state(Booking.name)
    await callback.message.answer(
        "📅 Давайте оформим заявку!\n\n"
        "Как вас зовут?"
    )
    await callback.answer()


@dp.message(Booking.name)
async def booking_name(message: Message, state: FSMContext):
    if not message.text:
        await message.answer("Напишите, пожалуйста, ваше имя.")
        return

    await state.update_data(name=message.text[:100])
    await state.set_state(Booking.dates)
    await message.answer(
        "На какие даты планируете отдых?\n"
        "Например: с 10 по 12 декабря."
    )


@dp.message(Booking.dates)
async def booking_dates(message: Message, state: FSMContext):
    if not message.text:
        await message.answer("Напишите даты текстом.")
        return

    await state.update_data(dates=message.text[:150])
    await state.set_state(Booking.guests)
    await message.answer("Сколько человек приедет?")


@dp.message(Booking.guests)
async def booking_guests(message: Message, state: FSMContext):
    if not message.text:
        await message.answer("Укажите количество гостей.")
        return

    await state.update_data(guests=message.text[:50])
    await state.set_state(Booking.phone)
    await message.answer(
        "Оставьте номер телефона для связи."
    )


@dp.message(Booking.phone)
async def booking_phone(message: Message, state: FSMContext):
    if not message.text:
        await message.answer("Напишите номер телефона текстом.")
        return

    data = await state.get_data()
    phone = message.text[:50]

    async with aiosqlite.connect(DB_NAME) as db:
        cursor = await db.execute(
            """
            INSERT INTO bookings
            (telegram_id, name, dates, guests, phone)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                message.from_user.id,
                data["name"],
                data["dates"],
                data["guests"],
                phone
            )
        )
        booking_id = cursor.lastrowid
        await db.commit()

    admin_notified = False

    if ADMIN_ID:
        try:
            await bot.send_message(
                int(ADMIN_ID),
                f"🔔 НОВАЯ ЗАЯВКА №{booking_id}\n\n"
                f"Имя: {data['name']}\n"
                f"Даты: {data['dates']}\n"
                f"Гости: {data['guests']}\n"
                f"Телефон: {phone}\n"
                f"Telegram ID: {message.from_user.id}\n\n"
                "Проверьте свободные даты и подтвердите бронь."
            )
            admin_notified = True
        except Exception:
            logging.exception("Не удалось уведомить администратора")

    await state.clear()

    if admin_notified:
        answer = (
            "✅ Заявка принята!\n\n"
            "Администратор проверит даты и свяжется с вами.\n"
            "Это пока не подтверждённая бронь."
        )
    else:
        answer = (
            "✅ Заявка сохранена!\n\n"
            "Администратор свяжется с вами для подтверждения.\n"
            "Это пока не подтверждённая бронь."
        )

    await message.answer(answer, reply_markup=main_menu())


@dp.callback_query(F.data == "admin")
async def contact_admin(callback: CallbackQuery):
    await callback.message.answer(
        "Напишите ваше сообщение следующим сообщением. "
        "Я передам его администратору."
    )
    await callback.answer()


@dp.message(F.text)
async def other_messages(message: Message):
    if ADMIN_ID:
        try:
            await bot.send_message(
                int(ADMIN_ID),
                "📩 Сообщение от гостя:\n\n"
                f"{message.text[:3000]}\n\n"
                f"Telegram ID: {message.from_user.id}"
            )
            await message.answer(
                "Ваше сообщение передано администратору. ❤️"
            )
            return
        except Exception:
            logging.exception("Ошибка передачи сообщения")

    await message.answer(
        "Пожалуйста, выберите нужный раздел в меню.",
        reply_markup=main_menu()
    )


async def health(request):
    return web.Response(text="Domovoy is running!")


async def webhook(request):
    received_secret = request.headers.get(
        "X-Telegram-Bot-Api-Secret-Token", ""
    )

    if not hmac.compare_digest(received_secret, WEBHOOK_SECRET):
        raise web.HTTPUnauthorized()

    try:
        data = await request.json()
        update = Update.model_validate(
            data,
            context={"bot": bot}
        )
        await dp.feed_update(bot, update)
    except Exception:
        logging.exception("Ошибка обработки обновления")
        raise web.HTTPInternalServerError()

    return web.Response(text="OK")


async def on_startup(app):
    await init_db()

    webhook_url = BASE_URL.rstrip("/") + "/webhook"

    await bot.set_webhook(
        webhook_url,
        secret_token=WEBHOOK_SECRET
    )

    logging.info("Webhook установлен: %s", webhook_url)


async def on_cleanup(app):
    await bot.session.close()


app = web.Application()
app.router.add_get("/", health)
app.router.add_post("/webhook", webhook)

app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)


if __name__ == "__main__":
    web.run_app(
        app,
        host="0.0.0.0",
        port=PORT
    )
