"""redbrain PII/money-скраб — единый источник паттернов.

Вынесен из dream.py (S1 temporal-layers): теперь скраб нужен и на входе
episodes.content (hot path инжеста), и в REM-выборках. Money-паттерны —
продолжение правила money-guard: суммы не живут ни в Трекере, ни в мозге.
"""
import re

PII_RE = re.compile(
    r"(\b\d{4}\s?\d{6}\b"                       # паспорт РФ
    r"|\b\d{12}\b|\b\d{15}\b"                    # ИНН(12)/ОГРНИП(15)
    r"|\b\d{3}-\d{3}-\d{3}\s?\d{2}\b"            # СНИЛС
    r"|\b\d{1,3}(?:\.\d{1,3}){3}\b"             # IPv4
    r"|\b[0-9a-f]{2,4}(?::[0-9a-f:]{2,})+/?\d*\b"  # IPv6-подобное
    r"|\+?\d[\d\s()-]{9,}\d"                     # телефон
    r"|[\w.+-]+@[\w-]+\.[\w.-]+"                 # email
    r"|(?:₽|\$|€|руб\.?|usd|eur)\s?\d[\d\s.,]{2,}"                          # деньги (валюта-префикс)
    r"|\d[\d\s.,]{2,}\s?(?:₽|руб\.?|р\.|rub|usd|\$|eur|€|млн|млрд|тыс|k)\b"  # деньги (суффикс)
    r")", re.IGNORECASE)


def scrub(s):
    """→ (clean_text, redacted:bool)."""
    clean, n = PII_RE.subn("[PII]", s)
    return clean, n > 0
