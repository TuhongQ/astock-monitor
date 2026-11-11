#!/usr/bin/env python3
"""Local AkShare bridge for AStockMonitor.

Install: python3 -m pip install akshare
Run:     python3 service/akshare_server.py
The upstream full-market snapshot is cached for 2 seconds and never fetched per symbol.
"""
from __future__ import annotations
import json
import math
import time
import threading
import socket
import hashlib
import importlib.util
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Reported on /health so the app can replace a bridge started by a Python
# interpreter that cannot import AkShare.
AKSHARE_AVAILABLE = importlib.util.find_spec("akshare") is not None

# Bound upstream calls that do not specify their own requests timeout.
socket.setdefaulttimeout(10)

HOST, PORT, CACHE_SECONDS = "127.0.0.1", 8767, 1.5
SHANGHAI_TZ = timezone(timedelta(hours=8))
API_VERSION = 20
INDEX_SYMBOLS = {
    "sh000001": "上证指数", "sz399001": "深证成指",
    "sz399006": "创业板指", "sh000680": "科创综指",
}
index_quote_cache: tuple[float, list[dict]] = (0.0, [])
index_history_cache: dict[str, tuple[float, list[dict]]] = {}
cache_by_provider: dict[str, list[dict]] = {}
cache_time_by_provider: dict[str, float] = {}
snapshot_fetch_seconds: dict[str, float] = {}
failure_by_provider: dict[str, tuple[float, str]] = {}
provider_locks: dict[str, threading.Lock] = {}
provider_locks_guard = threading.Lock()
classification_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="board-classification")
annual_profit_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="annual-profit")
classification_pending = False
classification_last_attempt = 0.0
classification_lock = threading.Lock()
classification_last_request = 0.0
classification_updated_at = 0.0
industry_by_code: dict[str, str] = {}
concepts_by_code: dict[str, set[str]] = {}
annual_profit_lock = threading.Lock()
annual_profit_by_code: dict[str, float] = {}
annual_profit_report_date = ""
quarterly_profit_by_code: dict[str, float] = {}
quarterly_profit_report_date = ""
quarterly_profit_label = ""
annual_profit_updated_at = 0.0
annual_profit_loading = False
annual_profit_last_failure = 0.0
ANNUAL_PROFIT_TTL = 24 * 60 * 60
market_cap_lock = threading.Lock()
market_cap_by_code: dict[str, dict[str, float]] = {}
market_cap_updated_at = 0.0
market_cap_loading = False
market_cap_last_failure = 0.0
daily_history_cache: dict[tuple[str, str], tuple[float, list[dict]]] = {}
daily_history_lock = threading.Lock()
five_day_trend_cache: dict[str, tuple[float, list[dict]]] = {}
FIVE_DAY_TREND_CACHE_SECONDS = 20
CLASSIFICATION_TTL_SECONDS = 24 * 60 * 60
CLASSIFICATION_MIN_INTERVAL = 0.9
CLASSIFICATION_SCHEMA_VERSION = 3
CLASSIFICATION_MIN_CONCEPT_STOCKS = 1000
CLASSIFICATION_RETRY_SECONDS = 60 * 60
DERIVED_DATA_RETRY_SECONDS = 5 * 60
CACHE_DIRECTORY = Path.home() / "Library" / "Application Support" / "AStockMonitor"
CLASSIFICATION_CACHE_PATH = CACHE_DIRECTORY / "market-classification.json"
ANNUAL_PROFIT_CACHE_PATH = CACHE_DIRECTORY / "annual-profit-cache.json"
MARKET_CAP_CACHE_PATH = CACHE_DIRECTORY / "market-cap-cache.json"
INDUSTRY_BOARD_ALIASES = {
    "农林牧渔": ("农林牧渔", "农产品加工", "种植业与林业", "养殖业"),
    "煤炭": ("煤炭",), "石油石化": ("石油石化", "石油行业", "石油天然气", "油气开采"),
    "有色金属": ("有色金属", "能源金属", "小金属", "贵金属", "工业金属"), "钢铁": ("钢铁",),
    "基础化工": ("基础化工", "化学原料", "化学制品", "化学纤维", "农药", "化肥", "橡胶制品", "塑料制品"),
    "建筑材料": ("建筑材料", "水泥建材", "玻璃玻纤", "装修建材"), "建筑装饰": ("建筑装饰", "工程建设", "装修装饰", "工程咨询"),
    "电力设备": ("电力设备", "电池", "光伏设备", "风电设备", "电网设备"), "机械设备": ("机械设备", "通用设备", "专用设备", "工程机械", "自动化设备"),
    "国防军工": ("国防军工", "航天航空", "航空装备", "军工"), "汽车": ("汽车整车", "汽车零部件", "汽车服务", "摩托车"),
    "交通运输": ("交通运输", "物流行业", "航运港口", "航空机场", "铁路公路"), "公用事业": ("公用事业", "电力行业", "燃气", "水务"),
    "房地产": ("房地产服务", "房地产开发"), "银行": ("银行",), "非银金融（证券、保险）": ("证券", "保险", "多元金融"),
    "食品饮料": ("食品饮料", "酿酒行业", "食品加工制造", "饮料制造"), "美容护理": ("美容护理",),
    "社会服务（旅游、酒店）": ("旅游酒店", "旅游景点", "酒店餐饮", "教育", "专业服务"),
    "商贸零售": ("商业百货", "贸易行业", "商业零售", "互联网电商"), "纺织服饰": ("纺织服装", "服装家纺", "纺织制造"),
    "轻工制造": ("轻工制造", "造纸印刷", "包装材料", "家用轻工"),
    "医药生物": ("医药生物", "化学制药", "中药", "生物制品", "医药商业", "医疗器械", "医疗服务"),
    "电子": ("电子元件", "半导体", "消费电子", "光学光电子"), "计算机": ("软件开发", "计算机设备", "IT服务", "互联网服务"),
    "传媒": ("文化传媒", "影视院线", "游戏", "广告营销"), "通信": ("通信设备", "通信服务"),
    "环保": ("环保行业", "环境治理"), "综合": ("综合行业",), "家用电器": ("家电行业", "家电"),
}
CONCEPT_BOARD_ALIASES = {
    "人工智能": ("人工智能", "AI应用", "AIGC", "AI智能体"), "算力": ("算力", "智算", "算力基础设施"),
    "半导体 / 芯片": ("半导体", "芯片"), "光伏": ("光伏",), "储能": ("储能",),
    "新能源车": ("新能源汽车", "新能源车", "汽车整车"), "锂电池": ("锂电池", "固态电池"),
    "机器人": ("机器人", "人形机器人"), "低空经济": ("低空经济", "飞行汽车"), "国产替代": ("国产替代", "自主可控"),
    "算力租赁": ("算力租赁", "数据中心", "IDC"), "数字经济": ("数字经济",), "国企改革": ("国企改革",),
    "一带一路": ("一带一路",), "碳中和": ("碳中和", "碳交易"), "CXO": ("CXO", "医药外包"),
    "创新药": ("创新药",), "MR/VR": ("MR", "VR", "虚拟现实"), "数据": ("数据要素", "数据安全", "大数据", "数据确权"),
}

def _read_json_cache(path: Path):
    try:
        with path.open("r", encoding="utf-8") as cache_file:
            return json.load(cache_file)
    except FileNotFoundError:
        return None
    except (OSError, ValueError, TypeError) as exc:
        print(f"Cache read failed ({path.name}): {exc}", flush=True)
        return None

def _write_json_cache(path: Path, payload: dict):
    """Atomically save slow-changing data; the quote polling path never writes these files."""
    try:
        CACHE_DIRECTORY.mkdir(parents=True, exist_ok=True)
        temporary_path = path.with_suffix(path.suffix + ".tmp")
        temporary_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temporary_path.replace(path)
        return True
    except (OSError, TypeError, ValueError) as exc:
        print(f"Cache write failed ({path.name}): {exc}", flush=True)
        return False

def _load_classification_cache():
    global industry_by_code, concepts_by_code, classification_updated_at
    payload = _read_json_cache(CLASSIFICATION_CACHE_PATH)
    if not isinstance(payload, dict):
        return
    try:
        industries = payload.get("industryByCode", {})
        concepts = payload.get("conceptsByCode", {})
        if not isinstance(industries, dict) or not isinstance(concepts, dict):
            raise ValueError("invalid cache structure")
        industry_by_code = {
            str(code).zfill(6): str(label)
            for code, label in industries.items()
            if str(code).isdigit() and len(str(code)) <= 6 and str(label)
        }
        concepts_by_code = {
            str(code).zfill(6): {str(label) for label in labels if str(label)}
            for code, labels in concepts.items()
            if str(code).isdigit() and len(str(code)) <= 6 and isinstance(labels, (list, tuple, set))
        }
        # Older caches only contained a handful of curated concept aliases.
        # Force one background rebuild that enumerates every concept board.
        cached_schema = int(payload.get("schemaVersion", 0))
        cache_is_complete = (cached_schema >= CLASSIFICATION_SCHEMA_VERSION
                             and len(concepts_by_code) >= CLASSIFICATION_MIN_CONCEPT_STOCKS)
        classification_updated_at = float(payload.get("updatedAt", 0)) if cache_is_complete else 0.0
        state = "complete" if cache_is_complete else "partial; refresh scheduled"
        print(f"Classification cache restored ({state}): industries={len(industry_by_code)}, tagged={len(concepts_by_code)}, schema={cached_schema}", flush=True)
    except (TypeError, ValueError) as exc:
        industry_by_code = {}
        concepts_by_code = {}
        classification_updated_at = 0.0
        print(f"Classification cache invalid; will refetch: {exc}", flush=True)

_load_classification_cache()


def _board_name_column(frame):
    for column in ("板块名称", "行业名称", "名称"):
        if column in frame.columns:
            return column
    return None

def _component_codes(frame):
    for column in ("代码", "股票代码", "证券代码", "code"):
        if column in frame.columns:
            values = frame[column]
            codes = set()
            for value in values:
                raw = str(value).strip()
                if raw.endswith(".0"):
                    raw = raw[:-2]
                digits = "".join(character for character in raw if character.isdigit())
                if digits:
                    codes.add(digits[-6:].zfill(6))
            return codes
    return set()

def _paced_classification_call(function, *args, **kwargs):
    global classification_last_request
    wait = CLASSIFICATION_MIN_INTERVAL - (time.time() - classification_last_request)
    if wait > 0:
        time.sleep(wait)
    classification_last_request = time.time()
    return function(*args, **kwargs)

def _read_board_memberships(ak, list_function, members_function, aliases, target_key):
    try:
        names_frame = list_function()
        name_column = _board_name_column(names_frame)
        if not name_column:
            print(f"Classification source missing board name column: {list(names_frame.columns)}", flush=True)
            return {}
        board_names = sorted({str(value).strip() for value in names_frame[name_column] if str(value).strip()})
    except Exception as exc:
        print(f"Classification board list failed ({target_key}): {exc}", flush=True)
        return {}

    result = {}
    requested = []
    for label, keywords in aliases.items():
        matches = [name for name in board_names if any(keyword.casefold() in name.casefold() for keyword in keywords)]
        requested.extend((name, label) for name in matches)
    # One board can match multiple requested labels; fetch each board only once.
    by_board = {}
    for name, label in requested:
        by_board.setdefault(name, set()).add(label)
    successes = 0
    for board_name, labels in by_board.items():
        try:
            frame = _paced_classification_call(members_function, board_name)
            codes = _component_codes(frame)
            if not codes:
                continue
            successes += 1
            for code in codes:
                result.setdefault(code, set()).update(labels)
            # Publish each board as it arrives so classification appears
            # progressively during a cold start instead of waiting for every
            # industry and concept request to finish.
            with classification_lock:
                if target_key == "industry":
                    industry_label = next(label for label in INDUSTRY_BOARD_ALIASES if label in labels)
                    industry_by_code.update({code: industry_label for code in codes})
                else:
                    for code in codes:
                        concepts_by_code.setdefault(code, set()).update(labels)
            if successes == 1 or successes % 10 == 0:
                print(f"Classification progress ({target_key}): boards={successes}/{len(by_board)}, stocks={len(result)}", flush=True)
        except Exception as exc:
            print(f"Classification members failed ({target_key} {board_name}): {exc}", flush=True)
    print(f"Classification memberships loaded ({target_key}): boards={successes}/{len(by_board)}, stocks={len(result)}", flush=True)
    return result

# 申万 2021 行业代码的前两位对应一级行业代码；映射到主界面的 31 个筛选标签。
SW_CODE_PREFIX_LABELS = {
    "11": "农林牧渔", "21": "煤炭", "22": "基础化工", "23": "钢铁",
    "24": "有色金属", "27": "电子", "28": "汽车", "33": "家用电器",
    "34": "食品饮料", "35": "纺织服饰", "36": "轻工制造", "37": "医药生物",
    "41": "公用事业", "42": "交通运输", "43": "房地产", "45": "商贸零售",
    "46": "社会服务（旅游、酒店）", "48": "银行", "49": "非银金融（证券、保险）",
    "51": "综合", "61": "建筑材料", "62": "建筑装饰", "63": "电力设备",
    "64": "机械设备", "65": "国防军工", "71": "计算机", "72": "传媒",
    "73": "通信", "75": "石油石化", "76": "环保", "77": "美容护理",
}

def _refresh_industries_from_sw(ak):
    """One-download fallback: map the SWS classification workbook to 31 sectors."""
    global industry_by_code, classification_updated_at
    frame = ak.stock_industry_clf_hist_sw()
    required = {"symbol", "start_date", "industry_code"}
    if frame is None or frame.empty or not required.issubset(frame.columns):
        raise RuntimeError(f"SWS stock classification schema changed: {list(frame.columns) if frame is not None else None}")
    latest = frame.sort_values("start_date").drop_duplicates("symbol", keep="last")
    result = {}
    for _, row in latest[["symbol", "industry_code"]].iterrows():
        code = str(row["symbol"]).strip()
        digits = "".join(character for character in code if character.isdigit())
        industry_code = str(row["industry_code"]).strip()
        label = SW_CODE_PREFIX_LABELS.get(industry_code[:2])
        if len(digits) >= 6 and label:
            result[digits[-6:].zfill(6)] = label
    if result:
        with classification_lock:
            industry_by_code.update(result)
            payload = {
                "updatedAt": time.time(),
                "industryByCode": dict(industry_by_code),
                "conceptsByCode": {code: sorted(labels) for code, labels in concepts_by_code.items()},
            }
            classification_updated_at = payload["updatedAt"]
        _write_json_cache(CLASSIFICATION_CACHE_PATH, payload)
        print(f"SWS industry fallback ready: sourceRows={len(frame)}, latestStocks={len(result)}, one workbook request", flush=True)
    return result

def _read_ths_concept_memberships(ak):
    """Fallback for concept tags; THS public board page exposes a paged member table."""
    try:
        import pandas as pd
        import requests
        from io import StringIO
        boards = ak.stock_board_concept_name_ths()
        name_col = next((c for c in ("name", "名称") if c in boards.columns), None)
        code_col = next((c for c in ("code", "代码") if c in boards.columns), None)
        if not name_col or not code_col:
            raise RuntimeError(f"THS concept list schema changed: {list(boards.columns)}")
    except Exception as exc:
        print(f"THS concept fallback board list failed: {exc}", flush=True)
        return {}

    by_board = {}
    names = [str(value).strip() for value in boards[name_col]]
    for label, keywords in CONCEPT_BOARD_ALIASES.items():
        for name in names:
            if any(keyword.casefold() in name.casefold() for keyword in keywords):
                code = str(boards.loc[boards[name_col] == name, code_col].iloc[0]).strip()
                by_board.setdefault((name, code), set()).add(label)

    result = {}
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36",
        "Referer": "http://q.10jqka.com.cn/gn/",
    }
    successes = 0
    for (name, board_code), labels in by_board.items():
        try:
            url = ("http://q.10jqka.com.cn/gn/detail/field/199112/order/desc/"
                   f"page/1/ajax/1/code/{board_code}")
            response = _paced_classification_call(requests.get, url, headers=headers, timeout=8)
            if response.status_code != 200:
                print(f"THS concept members unavailable ({name}, status={response.status_code})", flush=True)
                continue
            frame = pd.read_html(StringIO(response.text))[0]
            codes = _component_codes(frame)
            if not codes:
                continue
            successes += 1
            for code in codes:
                result.setdefault(code, set()).update(labels)
            with classification_lock:
                for code in codes:
                    concepts_by_code.setdefault(code, set()).update(labels)
            if successes % 10 == 0:
                print(f"THS concept fallback progress: boards={successes}/{len(by_board)}, stocks={len(result)}", flush=True)
        except Exception as exc:
            print(f"THS concept fallback failed ({name}): {exc}", flush=True)
    print(f"THS concept fallback ready: boards={successes}/{len(by_board)}, stocks={len(result)}; first page per board", flush=True)
    return result

def _read_all_concept_memberships(ak):
    """Fetch the complete per-stock theme map from Eastmoney's F10 report.

    Calling a constituent endpoint for every concept board is slow, and the old
    THS fallback only fetched page 1 for a small alias list. F10 returns the
    stock-to-board rows in pages of 5,000, so one paced daily refresh replaces
    hundreds of board calls while retaining the actual board names.
    """
    import requests

    endpoint = "https://datacenter-web.eastmoney.com/api/data/v1/get"
    params = {
        "reportName": "RPT_F10_CORETHEME_BOARDTYPE",
        "columns": "SECURITY_CODE,BOARD_NAME,BOARD_RANK",
        "source": "WEB", "client": "WEB",
        "pageSize": 5000, "pageNumber": 1,
        "sortColumns": "SECURITY_CODE,BOARD_RANK", "sortTypes": "1,1",
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36",
        "Referer": "https://data.eastmoney.com/",
    }
    session = requests.Session()
    result = {}
    failed_pages = []
    total_pages = 0
    total_rows = 0

    def read_page(page_number):
        page_params = dict(params, pageNumber=page_number)
        response = _paced_classification_call(session.get, endpoint, params=page_params, headers=headers, timeout=15)
        response.raise_for_status()
        payload = response.json()
        page = payload.get("result")
        if not isinstance(page, dict) or not isinstance(page.get("data"), list):
            raise RuntimeError(f"F10 response missing result.data: {str(payload)[:180]}")
        return page

    try:
        first_page = read_page(1)
        total_pages = int(first_page.get("pages") or 0)
        if total_pages < 1 or total_pages > 2000:
            raise RuntimeError(f"F10 returned invalid page count: {total_pages}")

        for page_number in range(1, total_pages + 1):
            if page_number == 1:
                page = first_page
            else:
                try:
                    page = read_page(page_number)
                except Exception as exc:
                    failed_pages.append(page_number)
                    print(f"F10 concept page failed page={page_number}/{total_pages}: {exc}", flush=True)
                    continue
            rows = page["data"]
            total_rows += len(rows)
            page_updates = {}
            for row in rows:
                raw_code = str(row.get("SECURITY_CODE", "")).strip()
                name = str(row.get("BOARD_NAME", "")).strip()
                if not raw_code.isdigit() or len(raw_code) > 6 or not name:
                    continue
                code = raw_code.zfill(6)
                labels = {name}
                for label, keywords in CONCEPT_BOARD_ALIASES.items():
                    if any(keyword.casefold() in name.casefold() for keyword in keywords):
                        labels.add(label)
                result.setdefault(code, set()).update(labels)
                page_updates.setdefault(code, set()).update(labels)

            # Publish each page as it arrives. The normal quote refresh can show
            # progressively richer concept labels during a cold start.
            with classification_lock:
                for code, labels in page_updates.items():
                    concepts_by_code.setdefault(code, set()).update(labels)
            if page_number == 1 or page_number % 5 == 0 or page_number == total_pages:
                print(f"F10 concept refresh progress: page={page_number}/{total_pages}, rows={total_rows}, stocks={len(result)}", flush=True)
    except Exception as exc:
        print(f"F10 concept source unavailable: {exc}", flush=True)
        return result, False
    finally:
        session.close()

    complete = (not failed_pages and total_rows > 0
                and len(result) >= CLASSIFICATION_MIN_CONCEPT_STOCKS)
    print(f"F10 concepts loaded: pages={total_pages - len(failed_pages)}/{total_pages}, rows={total_rows}, stocks={len(result)}, complete={complete}", flush=True)
    return result, complete

def _refresh_classifications():
    global classification_updated_at, industry_by_code, concepts_by_code
    global classification_pending
    try:
        import akshare as ak
        fetched_industries = _read_board_memberships(
            ak, ak.stock_board_industry_name_em, ak.stock_board_industry_cons_em,
            INDUSTRY_BOARD_ALIASES, "industry")
        fetched_concepts, concepts_complete = _read_all_concept_memberships(ak)

        if not fetched_industries:
            try:
                fetched_industries = _refresh_industries_from_sw(ak)
            except Exception as exc:
                print(f"SWS industry fallback failed: {exc}", flush=True)
        if not fetched_concepts:
            fetched_concepts = _read_ths_concept_memberships(ak)

        if fetched_industries or fetched_concepts:
            with classification_lock:
                if fetched_industries:
                    industry_by_code.update({
                        code: (labels if isinstance(labels, str) else
                               next((label for label in INDUSTRY_BOARD_ALIASES if label in labels), ""))
                        for code, labels in fetched_industries.items()
                    })
                complete_concept_refresh = (concepts_complete
                                            and len(fetched_concepts) >= CLASSIFICATION_MIN_CONCEPT_STOCKS)
                if complete_concept_refresh:
                    concepts_by_code = {code: set(labels) for code, labels in fetched_concepts.items()}
                elif fetched_concepts:
                    for code, labels in fetched_concepts.items():
                        concepts_by_code.setdefault(code, set()).update(labels)
                # Only mark the new schema complete after concept membership
                # was successfully fetched. If upstream rejects the request,
                # keep this cache stale so the normal retry window can recover.
                classification_updated_at = time.time() if complete_concept_refresh else 0.0
                payload = {
                    "schemaVersion": CLASSIFICATION_SCHEMA_VERSION if classification_updated_at else CLASSIFICATION_SCHEMA_VERSION - 1,
                    "updatedAt": time.time(),
                    "industryByCode": dict(industry_by_code),
                    "conceptsByCode": {code: sorted(labels) for code, labels in concepts_by_code.items()},
                }
            _write_json_cache(CLASSIFICATION_CACHE_PATH, payload)
            state = "complete" if classification_updated_at else "partial; will retry after cooldown"
            print(f"Classification refresh {state}: industries={len(payload['industryByCode'])}, tagged={len(payload['conceptsByCode'])}; daily disk cache", flush=True)
        else:
            print("Classification refresh returned no memberships; retaining previous cache", flush=True)
    except Exception as exc:
        print(f"Classification refresh failed: {exc}", flush=True)
    finally:
        with classification_lock:
            classification_pending = False

def ensure_classifications():
    global classification_pending, classification_last_attempt
    with classification_lock:
        stale = time.time() - classification_updated_at >= CLASSIFICATION_TTL_SECONDS
        if not stale or classification_pending or time.time() - classification_last_attempt < CLASSIFICATION_RETRY_SECONDS:
            return
        classification_pending = True
        classification_last_attempt = time.time()
    classification_executor.submit(_refresh_classifications)

def limit_ratio(code: str, name: str):
    """Daily price-limit ratio for an A-share, or None when no limit applies (new listings)."""
    upper_name = name.upper().strip()
    if upper_name[:1] in ("N", "C"):
        return None
    if code.startswith(("688", "689", "300", "301")):
        return 0.20
    if code.startswith(("8", "4", "92")):
        return 0.30
    return 0.05 if "ST" in upper_name else 0.10

def _round_price(value: float) -> float:
    # Exchange limit prices round half up to 0.01 yuan.
    return math.floor(value * 100 + 0.5 + 1e-7) / 100

def limit_prices(code, name, price, change_percent, prev_close=None):
    """Return (previous close, limit-up price, limit-down price, exact) for a quote."""
    ratio = limit_ratio(code, name)
    exact = bool(prev_close and prev_close > 0)
    if not exact:
        if price <= 0 or change_percent <= -99:
            return None, None, None, False
        prev_close = price / (1 + change_percent / 100)
    if ratio is None:
        return prev_close, None, None, exact
    return prev_close, _round_price(prev_close * (1 + ratio)), _round_price(prev_close * (1 - ratio)), exact

# ---------------------------------------------------------------------------
# 直连快照：东方财富 clist 并发分页 / 腾讯 qt.gtimg.cn 批量（约 0.15 秒全市场）
# AkShare 的腾讯接口逐页串行请求，全市场要 6 秒以上；交易所一档快照约 3 秒一更新，
# 直连后刷新间隔可以降到 3 秒。
# ---------------------------------------------------------------------------
fast_session_lock = threading.Lock()
fast_session_holder = {"session": None}
fast_executor = ThreadPoolExecutor(max_workers=16, thread_name_prefix="fast-quote")
EASTMONEY_FAST_URL = ("https://push2.eastmoney.com/api/qt/clist/get?pn={pn}&pz=100&po=1&np=1&fltt=2&invt=2&fid=f12"
                      "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048"
                      "&fields=f2,f3,f5,f6,f8,f10,f12,f14,f15,f16,f17,f18,f20,f21")
EASTMONEY_FAST_COLUMNS = {"f12": "代码", "f14": "名称", "f2": "最新价", "f3": "涨跌幅", "f5": "成交量", "f6": "成交额",
                          "f8": "换手率", "f10": "量比", "f15": "最高", "f16": "最低", "f17": "今开", "f18": "昨收",
                          "f20": "总市值", "f21": "流通市值"}

def _fast_session():
    with fast_session_lock:
        if fast_session_holder["session"] is None:
            import requests
            from requests.adapters import HTTPAdapter
            session = requests.Session()
            session.headers.update({"User-Agent": "Mozilla/5.0", "Referer": "https://quote.eastmoney.com/"})
            adapter = HTTPAdapter(pool_connections=4, pool_maxsize=32)
            session.mount("https://", adapter)
            fast_session_holder["session"] = session
        return fast_session_holder["session"]

def fetch_eastmoney_fast():
    import pandas as pd
    session = _fast_session()

    def page(pn):
        last_error = None
        for attempt in range(3):
            try:
                data = session.get(EASTMONEY_FAST_URL.format(pn=pn), timeout=4).json().get("data") or {}
                return data.get("diff") or [], data.get("total") or 0
            except Exception as exc:
                last_error = exc
                time.sleep(0.15 * (attempt + 1))
        raise RuntimeError(f"东方财富第 {pn} 页失败：{last_error}")

    first, total = page(1)
    if not total:
        raise RuntimeError("东方财富返回空列表")
    pages = (total + 99) // 100
    rows = list(first)
    for diff, _ in fast_executor.map(page, range(2, pages + 1)):
        rows.extend(diff)
    if len(rows) < total * 0.95:
        raise RuntimeError(f"东方财富快照不完整：{len(rows)}/{total}")
    frame = pd.DataFrame(rows).rename(columns=EASTMONEY_FAST_COLUMNS)
    return frame

def _tencent_symbol(code):
    if code.startswith(("6", "9")) and not code.startswith("92"):
        return "sh" + code
    if code.startswith(("8", "4", "92")):
        return "bj" + code
    return "sz" + code

def fetch_tencent_fast():
    """Direct qt.gtimg.cn batches; needs a code list from an earlier snapshot."""
    import pandas as pd
    codes = next((([row["code"] for row in rows]) for rows in cache_by_provider.values() if rows), None)
    if not codes:
        raise RuntimeError("腾讯直连需要先有一次全市场代码列表")
    session = _fast_session()

    def batch(group):
        response = session.get("https://qt.gtimg.cn/q=" + ",".join(_tencent_symbol(c) for c in group), timeout=4)
        response.encoding = "gbk"
        out = []
        for line in response.text.split(";"):
            if '="' not in line:
                continue
            f = line.split('="', 1)[1].split("~")
            if len(f) < 50:
                continue
            def num(index, scale=1.0):
                try:
                    return float(f[index]) * scale
                except (TypeError, ValueError):
                    return None
            out.append({"代码": f[2], "名称": f[1], "最新价": num(3), "昨收": num(4), "今开": num(5),
                        "成交量": num(6), "涨跌幅": num(32), "最高": num(33), "最低": num(34),
                        "成交额": num(37, 1e4), "换手率": num(38), "流通市值": num(44, 1e8), "总市值": num(45, 1e8),
                        "量比": num(49)})
        return out
    groups = [codes[i:i + 600] for i in range(0, len(codes), 600)]
    rows = [row for part in fast_executor.map(batch, groups) for row in part]
    if len(rows) < len(codes) * 0.9:
        raise RuntimeError(f"腾讯直连快照不完整：{len(rows)}/{len(codes)}")
    return pd.DataFrame(rows)

def get_market(provider="auto"):
    with provider_locks_guard:
        lock = provider_locks.setdefault(provider, threading.Lock())
    lock_started = time.monotonic()
    with lock:
        lock_wait = time.monotonic() - lock_started
        result = _get_market_locked(provider)
        # Return timing metadata to the HTTP handler without changing quote JSON.
        return result, lock_wait, snapshot_fetch_seconds.get(provider, 0.0), time.time() - cache_time_by_provider.get(provider, time.time())

def _get_market_locked(provider):
    request_started = time.monotonic()
    now = time.time()
    if now - cache_time_by_provider.get(provider, 0) < CACHE_SECONDS and cache_by_provider.get(provider):
        print(f"Snapshot cache hit provider={provider}; age={now - cache_time_by_provider[provider]:.2f}s; rows={len(cache_by_provider[provider])}", flush=True)
        return cache_by_provider[provider]
    print(f"Snapshot cache miss provider={provider}; cachedAge={now - cache_time_by_provider.get(provider, 0):.2f}s; starting upstream fetch", flush=True)
    # Avoid hammering upstream after a connection failure. Retry after 30 seconds.
    failed_at, previous_error = failure_by_provider.get(provider, (0, ""))
    if previous_error and now - failed_at < 30:
        raise RuntimeError(f"{provider} 数据源暂不可用，30 秒冷却中：{previous_error}")
    import akshare as ak
    funcs = {
        "eastmoney_fast": ("EastmoneyFast", fetch_eastmoney_fast),
        "tencent_fast": ("TencentFast", fetch_tencent_fast),
        "eastmoney": ("Eastmoney", ak.stock_zh_a_spot_em),
        "tencent": ("Tencent", ak.stock_zh_a_spot_tx),
        "sina": ("Sina", ak.stock_zh_a_spot),
    }
    # Tencent's paged snapshot is much faster on a cold start. Eastmoney remains
    # the fallback because it provides a wider set of fields but may take a minute.
    order = ["eastmoney_fast", "tencent_fast", "tencent", "eastmoney", "sina"] if provider == "auto" else [provider]
    errors = []
    frame = None
    source = ""
    for name in order:
        if name not in funcs:
            raise ValueError(f"未知行情源: {provider}")
        label, fetcher = funcs[name]
        try:
            frame = fetcher(); source = label
            break
        except Exception as exc:
            errors.append(f"{label}: {exc}")
            print(f"{label} snapshot failed: {exc}", flush=True)
    if frame is None:
        error_text = " | ".join(errors)
        failure_by_provider[provider] = (time.time(), error_text)
        raise RuntimeError(error_text)

    def value(row, keys, default=None):
        for key in keys:
            try:
                raw = row[key]
                if raw is not None and str(raw) not in ("--", "nan", "None", ""):
                    return raw
            except (KeyError, TypeError):
                continue
        return default
    def number(row, keys, default=0):
        try: return float(value(row, keys, default))
        except (TypeError, ValueError): return default
    rows = []
    for _, row in frame.iterrows():
        code = str(value(row, ["代码", "code"], ""))
        code = code[-6:].zfill(6)
        name = str(value(row, ["名称", "name"], ""))
        # AkShare's Tencent endpoint uses compact field names (zxj/zdf/lb/hsl).
        # Without these aliases it returned valid codes with zero prices, which
        # made the UI look empty because suspended stocks are hidden by default.
        price = number(row, ["最新价", "price", "trade", "zxj"])
        volume = number(row, ["成交量", "volume"])
        amount = number(row, ["成交额", "amount"])
        if source == "Tencent":
            # Tencent reports volume in lots and omits traded amount; estimate
            # it using 100 shares per lot. Markets may differ slightly by source.
            amount = volume * price * 100
        turnover = number(row, ["换手率", "turnover_rate", "turnoverratio", "hsl"], None)
        volume_ratio = number(row, ["量比", "volume_ratio", "lb"], None)
        total_market_cap = number(row, ["总市值", "total_market_cap", "totalMarketCap", "market_cap", "zsz"], None)
        float_market_cap = number(row, ["流通市值", "float_market_cap", "nmc", "ltsz"], None)
        if source == "Tencent" and float_market_cap is not None:
            float_market_cap *= 100_000_000
        if source == "Tencent" and total_market_cap is not None:
            total_market_cap *= 100_000_000
        change_percent = number(row, ["涨跌幅", "change_rate", "change_percent", "percent", "zdf"])
        def positive(keys):
            parsed = number(row, keys, None)
            return parsed if parsed is not None and math.isfinite(parsed) and parsed > 0 else None
        open_price = positive(["今开", "open", "jkj"])
        high_price = positive(["最高", "high", "zgj"])
        low_price = positive(["最低", "low", "zdj"])
        prev_close_raw = positive(["昨收", "settlement", "pre_close", "zsj"])
        prev_close, limit_up, limit_down, exact = limit_prices(code, name, price, change_percent, prev_close_raw)
        # Estimated previous closes come from a rounded change percentage, so
        # also require the change itself to be at the limit before flagging.
        tolerance = 0.005 if exact else 0.006
        ratio = limit_ratio(code, name)
        near_ratio = (ratio * 100 - 0.2) if ratio else None
        upper_limit = bool(price > 0 and limit_up and price >= limit_up - tolerance
                           and (exact or change_percent >= near_ratio))
        lower_limit = bool(price > 0 and limit_down and price <= limit_down + tolerance
                           and (exact or change_percent <= -near_ratio))
        rows.append({
            "code": code, "name": name, "price": price,
            "changePercent": change_percent,
            "open": open_price, "high": high_price, "low": low_price,
            "prevClose": round(prev_close, 3) if prev_close else None,
            "limitUpPrice": limit_up, "limitDownPrice": limit_down,
            "volume": volume,
            "amount": amount,
            "turnover": turnover,
            "volumeRatio": volume_ratio,
            "totalMarketCap": total_market_cap,
            "floatMarketCap": float_market_cap,
            "industry": "", "concept": "", "suspended": price <= 0,
            "isST": "ST" in name.upper(), "upperLimit": upper_limit, "lowerLimit": lower_limit,
            "bidAmount": None, "timestamp": datetime.now().astimezone().isoformat(timespec="seconds")
        })
    cache_by_provider[provider], cache_time_by_provider[provider] = rows, time.time()
    failure_by_provider.pop(provider, None)
    try:
        record_ticks(rows)
    except Exception as exc:
        print(f"Tick sampling failed: {exc}", flush=True)
    elapsed = time.monotonic() - request_started
    snapshot_fetch_seconds[provider] = elapsed
    print(f"Market snapshot ready from {source}: {len(rows)} rows; fetch={elapsed:.2f}s; cache={CACHE_SECONDS}s", flush=True)
    return rows

def latest_complete_annual_report_date():
    now = datetime.now()
    # Annual reports are normally due by April 30. Before then, use the
    # preceding year's completed report period.
    year = now.year - 1 if now.month >= 5 else now.year - 2
    return f"{year}1231"

def latest_complete_quarter_dates():
    now = datetime.now()
    # Select the latest quarter whose filing window has normally closed.
    if now.month >= 11:
        year, quarter, previous, label = now.year, "0930", "0630", "Q3"
    elif now.month >= 9:
        year, quarter, previous, label = now.year, "0630", "0331", "Q2"
    elif now.month >= 5:
        year, quarter, previous, label = now.year, "0331", None, "Q1"
    else:
        year, quarter, previous, label = now.year - 1, "0930", "0630", "Q3"
    current_date = f"{year}{quarter}"
    previous_date = f"{year}{previous}" if previous else None
    return current_date, previous_date, f"{year}{label}"

def annual_profit_map(frame):
    code_column, profit_column = "股票代码", "净利润-净利润"
    if frame is None or frame.empty or code_column not in frame or profit_column not in frame:
        raise RuntimeError("年报季报数据没有返回净利润字段")
    profits = {}
    for _, row in frame[[code_column, profit_column]].iterrows():
        code = str(row[code_column]).strip().zfill(6)
        try:
            value = float(row[profit_column])
            if code.isdigit() and len(code) == 6 and math.isfinite(value):
                profits[code] = value
        except (TypeError, ValueError):
            continue
    if not profits:
        raise RuntimeError("年报季报数据未解析到有效净利润")
    return profits

def refresh_annual_profit(report_date, quarter_date, previous_quarter_date, quarter_label):
    global annual_profit_by_code, annual_profit_report_date, annual_profit_updated_at
    global quarterly_profit_by_code, quarterly_profit_report_date, quarterly_profit_label
    global annual_profit_loading, annual_profit_last_failure
    try:
        import akshare as ak
        annual_profits = annual_profit_map(ak.stock_yjbb_em(date=report_date))
        quarter_cumulative = annual_profit_map(ak.stock_yjbb_em(date=quarter_date))
        if previous_quarter_date:
            previous_cumulative = annual_profit_map(ak.stock_yjbb_em(date=previous_quarter_date))
            quarter_profits = {code: value - previous_cumulative.get(code, 0.0) for code, value in quarter_cumulative.items()}
        else:
            # Q1's year-to-date net profit is the standalone quarter result.
            quarter_profits = quarter_cumulative
        updated_at = time.time()
        _write_json_cache(ANNUAL_PROFIT_CACHE_PATH, {
            "updatedAt": updated_at,
            "reportDate": report_date,
            "profits": annual_profits,
            "quarterReportDate": quarter_date,
            "quarterLabel": quarter_label,
            "quarterProfits": quarter_profits,
        })
        with annual_profit_lock:
            annual_profit_by_code = annual_profits
            annual_profit_report_date = report_date
            quarterly_profit_by_code = quarter_profits
            quarterly_profit_report_date = quarter_date
            quarterly_profit_label = quarter_label
            annual_profit_updated_at = updated_at
            annual_profit_last_failure = 0.0
        print(f"Financial profit data ready: annual={report_date[:4]} stocks={len(annual_profits)}, quarter={quarter_label} stocks={len(quarter_profits)}", flush=True)
    except Exception as exc:
        with annual_profit_lock:
            annual_profit_last_failure = time.time()
        print(f"Annual net profit load failed for {report_date}: {exc}", flush=True)
    finally:
        with annual_profit_lock:
            annual_profit_loading = False

def _restore_annual_profit_cache(report_date, quarter_date):
    global annual_profit_by_code, annual_profit_report_date, annual_profit_updated_at
    global quarterly_profit_by_code, quarterly_profit_report_date, quarterly_profit_label
    payload = _read_json_cache(ANNUAL_PROFIT_CACHE_PATH)
    if not isinstance(payload, dict):
        return
    if payload.get("reportDate") != report_date or payload.get("quarterReportDate") != quarter_date:
        print("Annual profit cache has an older reporting period; will refresh", flush=True)
        return

    def valid_map(values):
        if not isinstance(values, dict):
            return {}
        parsed = {}
        for code, value in values.items():
            try:
                amount = float(value)
                code = str(code).zfill(6)
                if code.isdigit() and len(code) == 6 and math.isfinite(amount):
                    parsed[code] = amount
            except (TypeError, ValueError):
                continue
        return parsed

    annual = valid_map(payload.get("profits", payload.get("annualProfits", {})))
    quarterly = valid_map(payload.get("quarterProfits", {}))
    try:
        updated_at = float(payload.get("updatedAt", 0))
    except (TypeError, ValueError):
        updated_at = 0.0
    if not annual or not quarterly or updated_at <= 0:
        print("Annual profit cache is incomplete; will refresh", flush=True)
        return
    with annual_profit_lock:
        annual_profit_by_code = annual
        annual_profit_report_date = report_date
        quarterly_profit_by_code = quarterly
        quarterly_profit_report_date = quarter_date
        quarterly_profit_label = str(payload.get("quarterLabel", ""))
        annual_profit_updated_at = updated_at
    print(f"Financial profit cache restored: annual={len(annual)}, quarter={len(quarterly)}", flush=True)

def ensure_annual_profit_data():
    global annual_profit_by_code, annual_profit_report_date, annual_profit_updated_at
    global quarterly_profit_by_code, quarterly_profit_report_date, quarterly_profit_label, annual_profit_loading
    report_date = latest_complete_annual_report_date()
    quarter_date, previous_quarter_date, quarter_label = latest_complete_quarter_dates()
    with annual_profit_lock:
        cache_needs_restore = (annual_profit_report_date != report_date
                               or quarterly_profit_report_date != quarter_date
                               or not annual_profit_by_code)
    if cache_needs_restore:
        _restore_annual_profit_cache(report_date, quarter_date)
    with annual_profit_lock:
        if (annual_profit_report_date == report_date and quarterly_profit_report_date == quarter_date
                and time.time() - annual_profit_updated_at < ANNUAL_PROFIT_TTL):
            return
        if annual_profit_loading or time.time() - annual_profit_last_failure < 3600:
            return
        annual_profit_loading = True
    annual_profit_executor.submit(refresh_annual_profit, report_date, quarter_date, previous_quarter_date, quarter_label)

def refresh_market_caps():
    global market_cap_by_code, market_cap_updated_at, market_cap_loading, market_cap_last_failure
    try:
        import akshare as ak
        frame = ak.stock_zh_a_spot_em()
        required = {"代码", "总市值", "流通市值"}
        if frame is None or frame.empty or not required.issubset(frame.columns):
            raise RuntimeError("东方财富快照未返回总市值和流通市值字段")
        values = {}
        for _, row in frame[["代码", "总市值", "流通市值"]].iterrows():
            code = str(row["代码"]).strip().zfill(6)
            if not code.isdigit() or len(code) != 6:
                continue
            try:
                total = float(row["总市值"])
                floating = float(row["流通市值"])
                if math.isfinite(total) and math.isfinite(floating):
                    values[code] = {"total": total, "float": floating}
            except (TypeError, ValueError):
                continue
        if not values:
            raise RuntimeError("东方财富快照未解析到有效市值")
        updated_at = time.time()
        _write_json_cache(MARKET_CAP_CACHE_PATH, {"updatedAt": updated_at, "values": values})
        with market_cap_lock:
            market_cap_by_code = values
            market_cap_updated_at = updated_at
            market_cap_last_failure = 0.0
        print(f"Market capitalization data ready: stocks={len(values)}; memory TTL={ANNUAL_PROFIT_TTL}s", flush=True)
    except Exception as exc:
        with market_cap_lock:
            market_cap_last_failure = time.time()
        print(f"Market capitalization load failed: {exc}", flush=True)
    finally:
        with market_cap_lock:
            market_cap_loading = False

def _restore_market_cap_cache():
    global market_cap_by_code, market_cap_updated_at
    payload = _read_json_cache(MARKET_CAP_CACHE_PATH)
    if not isinstance(payload, dict) or not isinstance(payload.get("values"), dict):
        return
    values = {}
    for code, row in payload["values"].items():
        if not isinstance(row, dict):
            continue
        try:
            code = str(code).zfill(6)
            total = float(row["total"])
            floating = float(row["float"])
            if code.isdigit() and len(code) == 6 and math.isfinite(total) and math.isfinite(floating):
                values[code] = {"total": total, "float": floating}
        except (KeyError, TypeError, ValueError):
            continue
    try:
        updated_at = float(payload.get("updatedAt", 0))
    except (TypeError, ValueError):
        updated_at = 0.0
    if values and updated_at > 0:
        with market_cap_lock:
            market_cap_by_code = values
            market_cap_updated_at = updated_at
        print(f"Market capitalization cache restored: stocks={len(values)}", flush=True)

def ensure_market_cap_data():
    global market_cap_by_code, market_cap_updated_at, market_cap_loading
    with market_cap_lock:
        cache_needs_restore = not market_cap_by_code
    if cache_needs_restore:
        _restore_market_cap_cache()
    with market_cap_lock:
        if market_cap_by_code and time.time() - market_cap_updated_at < ANNUAL_PROFIT_TTL:
            return
        if market_cap_loading or time.time() - market_cap_last_failure < DERIVED_DATA_RETRY_SECONDS:
            return
        market_cap_loading = True
    annual_profit_executor.submit(refresh_market_caps)

def fetch_daily_rows(code: str, cache_range: str = "year"):
    """Forward-adjusted daily bars, oldest first, shared by charts and the screener.

    One year (or full history) is cached for six hours so switching chart ranges
    and repeated screener passes do not hit the upstream again.
    Returns (rows, source) where source is "cache", "Eastmoney" or "Sina".
    """
    _load_daily_disk_cache()
    keys = [(code, cache_range)] + ([(code, "all")] if cache_range == "year" else [])
    with daily_history_lock:
        for key in keys:
            cached = daily_history_cache.get(key)
            if cached and time.time() - cached[0] < 6 * 60 * 60:
                return cached[1], "cache"
    import akshare as ak
    now = datetime.now(SHANGHAI_TZ)
    end = now.strftime("%Y%m%d")
    start = (now - timedelta(days=365)).strftime("%Y%m%d") if cache_range == "year" else "19900101"
    try:
        frame = ak.stock_zh_a_hist(symbol=code, period="daily", start_date=start, end_date=end, adjust="qfq")
        source = "Eastmoney"
    except Exception as exc:
        prefix = "sh" if code.startswith(("6", "9")) else "sz"
        print(f"Eastmoney daily history failed for {code}: {exc}; trying Sina", flush=True)
        frame = ak.stock_zh_a_daily(symbol=prefix + code, start_date=start, end_date=end, adjust="qfq")
        source = "Sina"
    rows = []
    if frame is not None and not frame.empty:
        for _, row in frame.iterrows():
            try:
                stamp = str(row.get("日期", row.get("date", "")))[:10]
                values = {
                    "open": float(row.get("开盘", row.get("open", 0))),
                    "high": float(row.get("最高", row.get("high", 0))),
                    "low": float(row.get("最低", row.get("low", 0))),
                    "close": float(row.get("收盘", row.get("close", 0))),
                }
                if not stamp or not all(math.isfinite(v) and v > 0 for v in values.values()):
                    continue
                try:
                    amount = float(row.get("成交额", row.get("amount", 0)) or 0)
                except (TypeError, ValueError):
                    amount = 0.0
                rows.append({"date": stamp, **values, "amount": amount if math.isfinite(amount) else 0.0})
            except (TypeError, ValueError):
                continue
    with daily_history_lock:
        daily_history_cache[(code, cache_range)] = (time.time(), rows)
    return rows, source

# ---------------------------------------------------------------------------
# 多策略量化选股（Multi-strategy screener）
#
# 由四类数据驱动，全部在本机计算：
#   * 全市场快照（每轮行情刷新已经抓取，不额外请求上游）；
#   * 盘中逐快照跟踪：涨速、5 分钟内从低点拉升幅度、分钟成交额放大倍数、
#     速拉事件（时间、起点、峰值、承接），每 5 分钟收盘价的日内轨迹；
#   * 东方财富涨停池 / 炸板池 / 昨日涨停池：连板数、首次封板时间、炸板次数、
#     封板资金、昨日涨停溢价，并按日保存近 15 个交易日涨停名单（强势股池）；
#   * 近一年前复权日线（按需拉取，内存 6 小时 + 磁盘按日缓存）。
#
# 策略彼此独立，各自打分（0–100，A ≥ 75、B ≥ 60）：
#   surge    速拉异动：盘中资金攻击，看拉升幅度、额速、承接、板块联动、日线位置
#   limit    涨停接力：冲板 / 封板 / 回封，看封板时间、炸板、连板高度、封单、梯队、情绪
#   trend    趋势突破：均线多头 / 粘合、振幅收敛、平台突破、放量结构、MACD
#   pullback 强势回踩：近 15 日有涨停的强势股缩量回踩 10 / 20 日线
#   leader   板块龙头：最强行业与题材中涨幅、成交额、封板时间领先的个股
#   tail     尾盘潜伏：14:30 后温和放量、收在高位、午后稳步走高的个股
# 结果是规则化的观察名单，不预测涨跌，也不构成买入建议。
# ---------------------------------------------------------------------------
from collections import deque, Counter

POTENTIAL_STAGE1_LIMIT = 80
POTENTIAL_RESULT_LIMIT = 30
POTENTIAL_MIN_SCORE = 50
POTENTIAL_HISTORY_INTERVAL = 0.35
POTENTIAL_SESSION_TTL = 5 * 60
POTENTIAL_OFF_HOURS_TTL = 30 * 60
POTENTIAL_MAX_FETCHES = 260
LIVE_LIST_TTL = 12

TICK_WINDOW_SECONDS = 10 * 60
SURGE_LOOKBACK_SECONDS = 5 * 60
SURGE_MIN_RISE = 1.8
SURGE_EVENT_COOLDOWN = 3 * 60
SURGE_MAX_GAP = 40
SURGE_EVENTS_PATH = CACHE_DIRECTORY / "surge-events.json"
LIMIT_HISTORY_PATH = CACHE_DIRECTORY / "limit-history.json"
DAILY_DISK_CACHE_PATH = CACHE_DIRECTORY / "daily-bars-cache.json"

STRATEGY_META = [
    {"id": "all", "title": "综合", "icon": "square.stack.3d.up.fill",
     "summary": "各策略结果合并，多策略共振加分",
     "description": "把下面六种策略的结果按个股合并：取最高分，每多命中一种策略加 6 分。同时被多个独立逻辑选中的个股，信号更可靠。"},
    {"id": "surge", "title": "速拉异动", "icon": "bolt.fill",
     "summary": "盘中资金攻击：5 分钟内从低点快速拉升且放量",
     "description": "本机逐快照跟踪全市场，5 分钟内从低点拉升 ≥ 1.8% 记为一次速拉。评分看拉升幅度、拉升期间分钟成交额相对全天均速的放大倍数（额速）、拉升后的承接（回吐不超过三成）、同行业 / 同题材是否多只同时异动（板块联动）、多波攻击、发生时间（早盘更好）、日线是否同时突破 20 / 60 日高点；高位（近 20 日涨幅 > 50%）速拉、冲高回落、流动性不足扣分。观察位为速拉起点，跌破说明攻击失败。"},
    {"id": "limit", "title": "涨停接力", "icon": "flag.fill",
     "summary": "冲板 / 封板 / 回封，看封板质量与情绪周期",
     "description": "数据来自东方财富涨停池、炸板池和昨日涨停池，并结合快照中距涨停 2% 以内的冲板股。评分看封板时间（10 点前最强）、炸板次数、连板高度（2 进 3 最受资金青睐，5 板以上风险陡增）、封单占流通市值比例、同行业涨停数量（梯队）、炸板率和昨日涨停溢价（赚钱效应）、流通市值弹性；一字板难以买入、尾盘板、高位板扣分。"},
    {"id": "trend", "title": "趋势突破", "icon": "chart.line.uptrend.xyaxis",
     "summary": "均线多头 / 粘合后放量突破平台",
     "description": "全市场快照初筛约 80 只（成交额 ≥ 1 亿、量比放大、收在日内高位、行业强度，盘中速拉额外加分，不再因涨幅较大被排除），再用日 K 复核均线多头、均线粘合、振幅收敛、20 / 60 日平台突破、缩量后放量、红肥绿瘦、MACD 金叉；乖离过大、短期涨幅过大、放量滞涨、长上影扣分。"},
    {"id": "pullback", "title": "强势回踩", "icon": "arrow.uturn.up",
     "summary": "近期涨停过的强势股，缩量回踩 10 / 20 日线",
     "description": "候选来自近 15 个交易日出现过涨停的个股（强势股池，按日自动积累）。要求从 20 日高点回撤 6%–28%、仍在上行的 20 日线附近、近 5 日缩量；回踩 10 / 20 日线 2.5% 以内、下影承接、所属行业仍强加分；放量下跌、跌破 20 日线排除。适合低吸，不追高。"},
    {"id": "leader", "title": "板块龙头", "icon": "crown.fill",
     "summary": "最强行业与题材里的领涨个股",
     "description": "按中位涨幅、前五强平均涨幅和涨停家数给行业与题材打热度，取最热的 5 个行业和 6 个题材；在板块内按涨幅排名、成交额排名、是否涨停及封板早晚、盘中涨速挑出前两名。龙头往往先于板块启动、最后才退潮。"},
    {"id": "tail", "title": "尾盘潜伏", "icon": "moon.stars.fill",
     "summary": "14:30 后温和放量、收在高位的稳健个股",
     "description": "经典尾盘选股：涨幅 2.5%–6%、量比 ≥ 1.2、换手 3%–12%、流通市值 30–300 亿、收在日内高位，且午后 5 分钟线稳步走高、日线 5 日线在 10 日线上方、近 20 日涨幅不大。14:30 前显示的是预览结果。"},
    {"id": "overnight", "title": "尾盘隔夜", "icon": "sunrise.fill",
     "summary": "14:50 买入、次日冲高卖出：主板 / 创业科创各选次日大涨概率最高的 10 只",
     "description": "全市场（剔除 ST、北交所、停牌、涨停封死、跌停、成交额 < 5000 万）逐只估算「次日盘中最高价比现价高 3% / 5%」的概率。模型用 1490 只随机个股 2026 年以来约 16.5 万个交易日拟合，并做了样本外检验：入选前 10 只次日冲高 ≥5% 的实际比例约 33%（全市场约 12%），≥3% 约 49%（全市场约 25%）。最有效的因子是换手、振幅、成交额和上影线（盘中资金活跃），量比过大、尾盘追高（高于分时均价）反而减分。注意：这类股票次日开盘平均低开约 1%，开盘直接卖出期望为负；建议次日挂 +3% 止盈单，10:30 前未成交或跌破 −3% 止损就卖出。14:50 自动锁定当日推荐，此前为预览；排序每 12 秒随行情刷新。"},
]
STRATEGY_TITLES = {item["id"]: item["title"] for item in STRATEGY_META}

GENERIC_CONCEPT_KEYWORDS = (
    "融资融券", "深股通", "沪股通", "港股通", "富时罗素", "MSCI", "标准普尔", "标普", "道琼斯", "彭博",
    "中证", "上证", "深证", "HS300", "创业板综", "预盈预增", "预亏预减", "扭亏", "机构重仓", "QFII",
    "基金重仓", "社保重仓", "证金", "转债标的", "股权激励", "股权转让", "破净", "低价股", "百元股",
    "AH股", "B股", "GDR", "昨日", "养老金", "举牌", "参股", "送转", "央视50", "微盘股", "茅指数",
    "宁组合", "长江三角", "京津冀", "粤港澳", "成渝", "西部大开发", "东北振兴", "次新股", "注册制",
    "专精特新", "超级品牌", "红利", "高股息", "ST股", "壳资源", "并购重组", "回购", "分拆", "independent",
)

tick_lock = threading.Lock()
tick_state = {"day": "", "lastTs": 0.0, "dirty": False, "lastSave": 0.0}
tick_history: dict[str, deque] = {}
day_marks: dict[str, list] = {}
surge_events: dict[str, list] = {}

def _session_minute(now: datetime):
    """Trading minutes elapsed since 09:30 (0–240), or None outside the two sessions."""
    if now.weekday() >= 5:
        return None
    minute = now.hour * 60 + now.minute + now.second / 60
    if 570 <= minute <= 690:
        return minute - 570
    if 780 <= minute <= 900:
        return 120 + minute - 780
    return None

def _session_progress(now: datetime):
    """Fraction of today's 240 trading minutes elapsed, and whether the session has opened."""
    if now.weekday() >= 5:
        return 1.0, False
    minute = now.hour * 60 + now.minute
    if minute < 570:
        return 1.0, False
    if minute < 690:
        elapsed = minute - 570
    elif minute < 780:
        elapsed = 120
    elif minute < 900:
        elapsed = 120 + minute - 780
    else:
        return 1.0, True
    return max(elapsed, 5) / 240, True

# Typical A-share cumulative turnover profile (session minute -> share of the
# full day). Volume is U-shaped, so projecting a partial session linearly
# overstates the morning by up to ~1.7x.
VOLUME_PROFILE = [(0, 0.0), (15, 0.13), (30, 0.22), (60, 0.35), (90, 0.45), (120, 0.53),
                  (150, 0.61), (180, 0.69), (210, 0.79), (230, 0.90), (240, 1.0)]

def _volume_fraction(now: datetime) -> float:
    fraction, opened = _session_progress(now)
    if not opened or fraction >= 1:
        return 1.0
    minute = fraction * 240
    for (m0, v0), (m1, v1) in zip(VOLUME_PROFILE, VOLUME_PROFILE[1:]):
        if minute <= m1:
            return max(v0 + (v1 - v0) * (minute - m0) / (m1 - m0), 0.03)
    return 1.0

def _potential_ttl(now: datetime) -> int:
    fraction, opened = _session_progress(now)
    return POTENTIAL_SESSION_TTL if opened and fraction < 1 else POTENTIAL_OFF_HOURS_TTL

def _median(values):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2

def _mean(values):
    return sum(values) / len(values) if values else 0.0

def _stdev(values):
    if len(values) < 2:
        return 0.0
    average = _mean(values)
    return math.sqrt(sum((v - average) ** 2 for v in values) / len(values))

def _ema(values, span):
    alpha = 2 / (span + 1)
    result, current = [], values[0]
    for value in values:
        current = alpha * value + (1 - alpha) * current
        result.append(current)
    return result

def _grade(score):
    return "A" if score >= 75 else ("B" if score >= 60 else "C")

def _clamp_score(score):
    return int(round(max(0, min(score, 100))))

def _is_tradeable_board(code, name):
    """Main board, ChiNext and STAR only; skip Beijing, ST, delisting and unlimited new listings."""
    upper = name.upper()
    if "ST" in upper or "退" in name:
        return False
    if code.startswith(("8", "4", "92")):
        return False
    return limit_ratio(code, name) is not None

def _useful_concepts(labels):
    return [label for label in labels
            if label and not any(keyword in label for keyword in GENERIC_CONCEPT_KEYWORDS)]

# ---------------------------------------------------------------------------
# 盘中逐快照跟踪
# ---------------------------------------------------------------------------
def _restore_surge_events(day):
    surge_events.clear()
    payload = _read_json_cache(SURGE_EVENTS_PATH)
    if isinstance(payload, dict) and payload.get("day") == day and isinstance(payload.get("events"), dict):
        for code, events in payload["events"].items():
            if isinstance(events, list):
                surge_events[str(code)] = [event for event in events if isinstance(event, dict) and "ts" in event]
        print(f"Surge events restored for {day}: stocks={len(surge_events)}", flush=True)

def _ensure_tick_day(day):
    """Caller holds tick_lock."""
    if tick_state["day"] != day:
        tick_history.clear()
        day_marks.clear()
        _restore_surge_events(day)
        tick_state["day"] = day

def record_ticks(rows):
    """Sample every fresh snapshot during the session; detect rapid-rise (速拉) events."""
    now = datetime.now(SHANGHAI_TZ)
    session_minute = _session_minute(now)
    if session_minute is None:
        return
    ts = time.time()
    day = now.strftime("%Y-%m-%d")
    clock = now.strftime("%H:%M:%S")
    new_events = 0
    with tick_lock:
        _ensure_tick_day(day)
        if ts - tick_state["lastTs"] < 3:
            return
        tick_state["lastTs"] = ts
        mark_slot = int(session_minute // 5)
        average_minutes = max(session_minute, 1.0)
        for row in rows:
            price = row.get("price") or 0
            if price <= 0 or row.get("suspended"):
                continue
            code = row["code"]
            amount = row.get("amount") or 0.0
            history = tick_history.get(code)
            if history is None:
                history = tick_history[code] = deque()
            history.append((ts, price, amount))
            while history and ts - history[0][0] > TICK_WINDOW_SECONDS:
                history.popleft()
            marks = day_marks.setdefault(code, [])
            if marks and marks[-1][0] == mark_slot:
                marks[-1] = (mark_slot, price)
            else:
                marks.append((mark_slot, price))

            code_events = surge_events.get(code)
            if code_events and ts - code_events[-1]["ts"] < 30 * 60 and price > code_events[-1]["peak"]:
                code_events[-1]["peak"] = price
            if len(history) < 2:
                continue
            low_price, low_ts, low_amount = price, ts, amount
            cursor = ts
            for sample_ts, sample_price, sample_amount in reversed(history):
                if cursor - sample_ts > SURGE_MAX_GAP or ts - sample_ts > SURGE_LOOKBACK_SECONDS:
                    break
                if sample_price < low_price:
                    low_price, low_ts, low_amount = sample_price, sample_ts, sample_amount
                cursor = sample_ts
            if low_ts >= ts or low_price <= 0:
                continue
            rise = (price / low_price - 1) * 100
            if rise < SURGE_MIN_RISE:
                continue
            seconds = ts - low_ts
            amount_delta = max(amount - low_amount, 0.0)
            day_minute_amount = amount / average_minutes
            accel = (amount_delta / max(seconds / 60, 0.5)) / day_minute_amount if day_minute_amount > 0 else 0.0
            prev_close = row.get("prevClose") or 0
            event = {
                "ts": ts, "time": clock, "low": round(low_price, 3), "price": round(price, 3),
                "peak": round(price, 3), "rise": round(rise, 2), "seconds": int(seconds),
                "amountDelta": round(amount_delta), "accel": round(accel, 2),
                "dayChange": round(row.get("changePercent") or 0, 2),
                "startChange": round((low_price / prev_close - 1) * 100, 2) if prev_close else None,
                "sessionMinute": round(session_minute, 1),
            }
            if code_events and ts - code_events[-1]["ts"] < SURGE_EVENT_COOLDOWN and low_ts <= code_events[-1]["ts"]:
                # The same move is still extending: keep one event and update it.
                last = code_events[-1]
                if rise > last["rise"]:
                    event["time"] = last["time"]; event["ts"] = last["ts"]
                    event["peak"] = max(last["peak"], price)
                    code_events[-1] = event
            elif not code_events or ts - code_events[-1]["ts"] >= SURGE_EVENT_COOLDOWN:
                surge_events.setdefault(code, []).append(event)
                new_events += 1
        if new_events:
            tick_state["dirty"] = True
        save_payload = None
        if tick_state["dirty"] and ts - tick_state["lastSave"] >= 30:
            save_payload = {"day": day, "events": {code: list(events[-20:]) for code, events in surge_events.items()}}
            tick_state["dirty"] = False
            tick_state["lastSave"] = ts
    if save_payload:
        _write_json_cache(SURGE_EVENTS_PATH, save_payload)
    if new_events:
        print(f"Surge events detected: new={new_events}, stocksToday={len(surge_events)}", flush=True)

def tick_metrics(code, quote, now_ts=None):
    """Live speed metrics from local samples. Empty dict when no samples exist."""
    now_ts = now_ts or time.time()
    with tick_lock:
        history = list(tick_history.get(code, ()))
    if len(history) < 2:
        return {}
    last_ts, price, amount = history[-1]
    if now_ts - last_ts > 90:
        return {}

    def sample_before(seconds):
        target = last_ts - seconds
        chosen = None
        for sample in history:
            if sample[0] <= target + 5:
                chosen = sample
            else:
                break
        return chosen

    metrics = {}
    for label, seconds in (("speed1", 60), ("speed3", 180), ("speed5", 300)):
        sample = sample_before(seconds)
        if sample and sample[1] > 0 and last_ts - sample[0] <= seconds + 45:
            metrics[label] = (price / sample[1] - 1) * 100
    window = [s for s in history if last_ts - s[0] <= SURGE_LOOKBACK_SECONDS]
    low = min(window, key=lambda s: s[1])
    metrics["rise5"] = (price / low[1] - 1) * 100 if low[1] > 0 else 0.0
    peak_after_low = max(s[1] for s in window if s[0] >= low[0])
    metrics["retention"] = ((price - low[1]) / (peak_after_low - low[1])) if peak_after_low > low[1] else 1.0
    base = sample_before(180)
    session_minute = _session_minute(datetime.now(SHANGHAI_TZ)) or 240
    day_minute_amount = amount / max(session_minute, 1)
    if base and day_minute_amount > 0 and last_ts > base[0]:
        recent_minute_amount = max(amount - base[2], 0) / ((last_ts - base[0]) / 60)
        metrics["accel"] = recent_minute_amount / day_minute_amount
    return metrics

def day_mark_series(code):
    with tick_lock:
        return list(day_marks.get(code, ()))

def surge_events_snapshot():
    with tick_lock:
        _ensure_tick_day(datetime.now(SHANGHAI_TZ).strftime("%Y-%m-%d"))
        return {code: list(events) for code, events in surge_events.items() if events}

# ---------------------------------------------------------------------------
# 涨停池 / 炸板池 / 昨日涨停（情绪周期）
# ---------------------------------------------------------------------------
zt_lock = threading.Lock()
zt_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="limit-pool")
zt_state = {"updatedAt": 0.0, "lastAttempt": 0.0, "loading": False, "date": "",
            "pool": {}, "broken": {}, "previous": {}, "error": ""}
limit_history: dict[str, list[str]] = {}
limit_history_loaded = False
limit_history_bootstrapped = ""

def _num(value):
    try:
        parsed = float(value)
        return parsed if math.isfinite(parsed) else None
    except (TypeError, ValueError):
        return None

def _hms(value):
    digits = "".join(ch for ch in str(value) if ch.isdigit())
    if len(digits) < 4:
        return None
    digits = digits[-6:].zfill(6)
    return f"{digits[:2]}:{digits[2:4]}:{digits[4:6]}"

def _code6(value):
    digits = "".join(ch for ch in str(value) if ch.isdigit())
    return digits[-6:].zfill(6) if digits else ""

def _trading_date_candidates(now: datetime, count=8):
    """Latest trading date first (today once the 09:25 auction has printed)."""
    day = now
    if now.weekday() >= 5 or now.hour * 60 + now.minute < 565:
        day = now - timedelta(days=1)
    dates = []
    while len(dates) < count:
        if day.weekday() < 5:
            dates.append(day.strftime("%Y%m%d"))
        day -= timedelta(days=1)
    return dates

def _load_limit_history():
    global limit_history_loaded
    if limit_history_loaded:
        return
    limit_history_loaded = True
    payload = _read_json_cache(LIMIT_HISTORY_PATH)
    if isinstance(payload, dict) and isinstance(payload.get("dates"), dict):
        for date, codes in payload["dates"].items():
            if isinstance(codes, list):
                limit_history[str(date)] = [str(code).zfill(6) for code in codes]
        print(f"Limit-up history restored: days={len(limit_history)}", flush=True)

def _save_limit_history():
    kept = sorted(limit_history)[-20:]
    for date in list(limit_history):
        if date not in kept:
            limit_history.pop(date, None)
    _write_json_cache(LIMIT_HISTORY_PATH, {"updatedAt": time.time(), "dates": {d: limit_history[d] for d in kept}})

def _parse_zt_pool(frame, kind):
    result = {}
    if frame is None or frame.empty:
        return result
    for _, row in frame.iterrows():
        code = _code6(row.get("代码", ""))
        if not code:
            continue
        item = {
            "code": code, "name": str(row.get("名称", "")),
            "changePercent": _num(row.get("涨跌幅")), "price": _num(row.get("最新价")),
            "amount": _num(row.get("成交额")), "floatMarketCap": _num(row.get("流通市值")),
            "turnover": _num(row.get("换手率")), "industry": str(row.get("所属行业", "") or ""),
            "stat": str(row.get("涨停统计", "") or ""),
        }
        if kind == "pool":
            item.update(sealAmount=_num(row.get("封板资金")), firstTime=_hms(row.get("首次封板时间")),
                        lastTime=_hms(row.get("最后封板时间")), openCount=int(_num(row.get("炸板次数")) or 0),
                        streak=int(_num(row.get("连板数")) or 1))
        elif kind == "broken":
            item.update(firstTime=_hms(row.get("首次封板时间")), openCount=int(_num(row.get("炸板次数")) or 1),
                        limitUpPrice=_num(row.get("涨停价")), amplitude=_num(row.get("振幅")))
        else:
            item.update(prevStreak=int(_num(row.get("昨日连板数")) or 1), prevTime=_hms(row.get("昨日封板时间")))
        result[code] = item
    return result

def _refresh_zt():
    try:
        import akshare as ak
        _load_limit_history()
        now = datetime.now(SHANGHAI_TZ)
        chosen, pool, errors = "", {}, []
        for date in _trading_date_candidates(now, 6):
            try:
                frame = ak.stock_zt_pool_em(date=date)
            except Exception as exc:
                errors.append(f"{date}: {exc}")
                continue
            if frame is not None and not frame.empty:
                chosen, pool = date, _parse_zt_pool(frame, "pool")
                break
        if not chosen:
            raise RuntimeError("涨停池暂无数据 " + " | ".join(errors[-2:]))
        broken, previous = {}, {}
        try:
            broken = _parse_zt_pool(ak.stock_zt_pool_zbgc_em(date=chosen), "broken")
        except Exception as exc:
            print(f"Broken-limit pool unavailable for {chosen}: {exc}", flush=True)
        try:
            previous = _parse_zt_pool(ak.stock_zt_pool_previous_em(date=chosen), "previous")
        except Exception as exc:
            print(f"Previous limit-up pool unavailable for {chosen}: {exc}", flush=True)
        limit_history[chosen] = sorted(pool)
        _save_limit_history()
        with zt_lock:
            zt_state.update(updatedAt=time.time(), date=chosen, pool=pool, broken=broken,
                            previous=previous, error="")
        print(f"Limit-up pools ready {chosen}: sealed={len(pool)}, broken={len(broken)}, previous={len(previous)}", flush=True)
        _bootstrap_limit_history(ak, now, chosen)
    except Exception as exc:
        with zt_lock:
            zt_state["error"] = str(exc)
        print(f"Limit-up pool refresh failed: {exc}", flush=True)
    finally:
        with zt_lock:
            zt_state["loading"] = False

def _bootstrap_limit_history(ak, now, latest):
    """Fill the strong-stock pool with the past ~12 trading days once per day."""
    global limit_history_bootstrapped
    if limit_history_bootstrapped == latest:
        return
    limit_history_bootstrapped = latest
    wanted = [d for d in _trading_date_candidates(now, 14) if d != latest and d not in limit_history]
    if not wanted:
        return
    filled = 0
    for date in wanted:
        try:
            time.sleep(0.8)
            frame = ak.stock_zt_pool_em(date=date)
            if frame is not None and not frame.empty:
                limit_history[date] = sorted(_parse_zt_pool(frame, "pool"))
                filled += 1
        except Exception as exc:
            print(f"Limit-up history skipped {date}: {exc}", flush=True)
    if filled:
        _save_limit_history()
    print(f"Limit-up history bootstrap: filled={filled}/{len(wanted)}, days={len(limit_history)}", flush=True)

def ensure_zt():
    now = datetime.now(SHANGHAI_TZ)
    live = _session_minute(now) is not None
    ttl = 60 if live else 30 * 60
    with zt_lock:
        if zt_state["loading"]:
            return
        if time.time() - zt_state["updatedAt"] < ttl:
            return
        if time.time() - zt_state["lastAttempt"] < (30 if live else 300):
            return
        zt_state.update(loading=True, lastAttempt=time.time())
    zt_executor.submit(_refresh_zt)

def zt_snapshot():
    with zt_lock:
        return {key: zt_state[key] for key in ("updatedAt", "date", "pool", "broken", "previous", "error")}

def limit_emotion(zt):
    pool, broken, previous = zt["pool"], zt["broken"], zt["previous"]
    sealed = [item for item in pool.values() if "ST" not in item["name"].upper()]
    total_touched = len(pool) + len(broken)
    ladder = {}
    for item in sealed:
        ladder.setdefault(item.get("streak", 1), []).append(item)
    ladder_rows = [{"streak": streak, "count": len(items),
                    "names": [i["name"] for i in sorted(items, key=lambda i: i.get("firstTime") or "99")[:4]]}
                   for streak, items in sorted(ladder.items(), reverse=True)]
    industries = Counter(item["industry"] for item in sealed if item.get("industry"))
    previous_changes = [item["changePercent"] for item in previous.values()
                        if item.get("changePercent") is not None and "ST" not in item["name"].upper()]
    premium = _mean(previous_changes) if previous_changes else None
    broken_rate = len(broken) / total_touched if total_touched else None
    max_streak = max((item.get("streak", 1) for item in sealed), default=0)
    if broken_rate is None:
        mood = "未知"
    elif (premium or 0) >= 2 and broken_rate < 0.3 and max_streak >= 4:
        mood = "高潮"
    elif (premium or 0) <= -1 or broken_rate >= 0.45:
        mood = "退潮"
    elif (premium or 0) >= 0.8 and broken_rate < 0.35:
        mood = "回暖"
    else:
        mood = "分歧"
    return {
        "date": zt["date"], "limitUpCount": len(sealed), "brokenCount": len(broken),
        "brokenRate": round(broken_rate * 100, 1) if broken_rate is not None else None,
        "maxStreak": max_streak, "previousPremium": round(premium, 2) if premium is not None else None,
        "mood": mood, "ladder": ladder_rows[:6],
        "topIndustries": [{"name": name, "count": count} for name, count in industries.most_common(6)],
    }

# ---------------------------------------------------------------------------
# 日线特征
# ---------------------------------------------------------------------------
daily_disk_loaded = False

def _load_daily_disk_cache():
    global daily_disk_loaded
    if daily_disk_loaded:
        return
    daily_disk_loaded = True
    payload = _read_json_cache(DAILY_DISK_CACHE_PATH)
    if not isinstance(payload, dict) or not isinstance(payload.get("codes"), dict):
        return
    today = datetime.now(SHANGHAI_TZ).strftime("%Y-%m-%d")
    restored = 0
    with daily_history_lock:
        for code, entry in payload["codes"].items():
            if not isinstance(entry, dict) or entry.get("day") != today or not isinstance(entry.get("rows"), list):
                continue
            daily_history_cache.setdefault((code, "year"), (float(entry.get("fetchedAt", 0)), entry["rows"]))
            restored += 1
    print(f"Daily bar disk cache restored: {restored} stocks", flush=True)

def _save_daily_disk_cache():
    today = datetime.now(SHANGHAI_TZ).strftime("%Y-%m-%d")
    with daily_history_lock:
        entries = {code: {"day": datetime.fromtimestamp(stamp, SHANGHAI_TZ).strftime("%Y-%m-%d"),
                          "fetchedAt": stamp, "rows": rows[-260:]}
                   for (code, cache_range), (stamp, rows) in daily_history_cache.items()
                   if cache_range == "year" and rows}
    entries = {code: entry for code, entry in entries.items() if entry["day"] == today}
    if entries:
        _write_json_cache(DAILY_DISK_CACHE_PATH, {"codes": entries})

def cached_daily(code):
    _load_daily_disk_cache()
    with daily_history_lock:
        for key in ((code, "year"), (code, "all")):
            cached = daily_history_cache.get(key)
            if cached and time.time() - cached[0] < 6 * 60 * 60:
                return cached[1]
    return None

def daily_features(q, history, now, min_bars=60):
    """Reusable daily-bar features with the live session appended as today's bar."""
    if not history:
        return None
    today = now.strftime("%Y-%m-%d")
    bars = [b for b in history if b.get("date") != today]
    if len(bars) < min_bars:
        return None
    price, change = q["price"], q["changePercent"]
    last = bars[-1]
    previous_change = (last["close"] / bars[-2]["close"] - 1) * 100
    same_session = abs(last["close"] - price) < 0.006 and abs(previous_change - change) < 0.06
    fraction = _volume_fraction(now)
    if same_session:
        prior = bars[:-1]
        today_bar = dict(last)
        today_amount = last.get("amount", 0)
    else:
        prior = bars
        today_bar = {"open": q.get("open") or price, "high": max(q.get("high") or price, price),
                     "low": min(q.get("low") or price, price), "close": price}
        today_amount = (q.get("amount") or 0) / fraction
    closes = [b["close"] for b in prior] + [price]

    def sma(values, n):
        return _mean(values[-n:])
    ma5, ma10, ma20, ma60 = sma(closes, 5), sma(closes, 10), sma(closes, 20), sma(closes, 60)
    yesterday = closes[:-1]
    y5, y10, y20 = sma(yesterday, 5), sma(yesterday, 10), sma(yesterday, 20)
    amounts = [b.get("amount", 0) for b in prior if b.get("amount", 0) > 0]
    avg5, avg20 = _mean(amounts[-5:]), _mean(amounts[-20:])
    returns = [closes[i] / closes[i - 1] - 1 for i in range(1, len(closes))]
    ratio = limit_ratio(q["code"], q.get("name", ""))
    streak, limit_ups_15 = 0, 0
    if ratio:
        hits = [prior[i]["close"] / prior[i - 1]["close"] - 1 >= ratio - 0.003 for i in range(1, len(prior))]
        for hit in reversed(hits):
            if not hit:
                break
            streak += 1
        limit_ups_15 = sum(hits[-15:])
    ema12, ema26 = _ema(closes, 12), _ema(closes, 26)
    dif = [a - b for a, b in zip(ema12, ema26)]
    dea = _ema(dif, 9)
    window20 = prior[-20:]
    return {
        "price": price, "change": change, "prior": prior, "closes": closes, "todayBar": today_bar,
        "todayAmount": today_amount, "ma5": ma5, "ma10": ma10, "ma20": ma20, "ma60": ma60,
        "ma20Before": _mean(closes[-25:-5]), "maSpread": (max(y5, y10, y20) - min(y5, y10, y20)) / yesterday[-1],
        "high20": max(b["high"] for b in window20), "high60": max(b["high"] for b in prior[-60:]),
        "low20": min(b["low"] for b in window20),
        "avg5": avg5, "avg20": avg20,
        "amountRatio": today_amount / avg5 if avg5 > 0 and today_amount > 0 else None,
        "std10": _stdev(returns[-11:-1]), "std60": _stdev(returns[-61:-1]),
        "ret5": price / closes[-6] - 1, "ret20": price / closes[-21] - 1, "ret60": price / closes[-61] - 1,
        "bias20": price / ma20 - 1,
        "upAmount": sum(prior[i].get("amount", 0) for i in range(len(prior) - 20, len(prior)) if prior[i]["close"] >= prior[i - 1]["close"]),
        "downAmount": sum(prior[i].get("amount", 0) for i in range(len(prior) - 20, len(prior)) if prior[i]["close"] < prior[i - 1]["close"]),
        "dif": dif, "dea": dea,
        "goldenCross": any(dif[i - 1] <= dea[i - 1] and dif[i] > dea[i] for i in range(len(dif) - 3, len(dif))),
        "streak": streak, "limitUps15": limit_ups_15, "prevClose": closes[-2],
    }

def _base_item(q, strategy, score, signals, risks, *, pivot=None, stop=None, highlights=None, tags=None, extra=None):
    price = q["price"]
    if stop is not None and stop >= price:
        stop = price * 0.95
    item = {
        "code": q["code"], "name": q.get("name", ""), "price": price, "changePercent": q.get("changePercent", 0),
        "industry": q.get("industry") or None, "score": _clamp_score(score), "grade": _grade(score),
        "strategy": strategy, "strategies": [strategy],
        "signals": signals, "risks": risks, "highlights": highlights or [], "tags": tags or [],
        "pivot": round(pivot, 2) if pivot else None, "stopLoss": round(stop, 2) if stop else None,
        "riskPercent": round((price - stop) / price * 100, 2) if stop else None,
        "volumeRatio": q.get("volumeRatio"), "turnover": q.get("turnover"), "amount": q.get("amount"),
        "floatMarketCap": q.get("floatMarketCap"), "amountRatio": None, "ret20": None, "bias20": None,
    }
    item["grade"] = _grade(item["score"])
    if extra:
        item.update(extra)
    return item

def _daily_structure_bonus(f):
    """Shared daily-chart context for intraday strategies (only when bars are cached)."""
    score, signals, risks = 0.0, [], []
    p = f["price"]
    if p > f["high60"]:
        score += 12; signals.append("同时突破 60 日高点")
    elif p > f["high20"]:
        score += 8; signals.append("同时突破 20 日高点")
    if p > f["ma20"] > f["ma60"] and f["ma20"] > f["ma20Before"]:
        score += 6; signals.append("日线趋势向上")
    if f["ret20"] > 0.5:
        score -= 12; risks.append(f"近 20 日已涨 {f['ret20'] * 100:.0f}%，高位异动警惕出货")
    elif f["ret20"] > 0.3:
        score -= 5; risks.append(f"近 20 日已涨 {f['ret20'] * 100:.0f}%")
    if p < f["ma60"]:
        score -= 4; risks.append("仍在 60 日线下方")
    return score, signals, risks

# ---------------------------------------------------------------------------
# 策略：速拉异动
# ---------------------------------------------------------------------------
def strategy_surge(ctx):
    now_ts, live = time.time(), ctx["live"]
    events = ctx["surgeEvents"]
    recent_span = 30 * 60 if live else 24 * 3600
    resonance_span = 15 * 60 if live else 24 * 3600
    industry_heat, concept_heat = Counter(), Counter()
    for code, code_events in events.items():
        if now_ts - code_events[-1]["ts"] > resonance_span:
            continue
        industry = ctx["industryOf"](code)
        if industry:
            industry_heat[industry] += 1
        for concept in ctx["conceptsOf"](code):
            concept_heat[concept] += 1
    results = []
    for code, code_events in events.items():
        event = code_events[-1]
        if now_ts - event["ts"] > recent_span:
            continue
        q = ctx["byCode"].get(code)
        if not q or q.get("suspended") or q.get("price", 0) < 2 or not _is_tradeable_board(code, q.get("name", "")):
            continue
        if (q.get("amount") or 0) < 30_000_000:
            continue
        price, change = q["price"], q.get("changePercent", 0)
        metrics = tick_metrics(code, q, now_ts) if live else {}
        signals, risks, highlights, tags = [], [], [], []
        rise = max(event["rise"], metrics.get("rise5", 0))
        score = min(rise / 4, 1) * 22
        accel = max(event.get("accel") or 0, metrics.get("accel", 0))
        if accel > 0:
            score += min(max(math.log2(max(accel, 1)), 0) / 3, 1) * 18
        if accel >= 3:
            signals.append(f"拉升期间额速 {accel:.1f} 倍，资金主动攻击")
        peak = max(event.get("peak", price), price)
        retention = (price - event["low"]) / (peak - event["low"]) if peak > event["low"] else 1.0
        if retention >= 0.8:
            score += 10; signals.append("拉升后承接良好，几乎不回吐")
        elif retention >= 0.6:
            score += 6
        elif retention < 0.4:
            score -= 8; risks.append(f"冲高回落，回吐 {100 - retention * 100:.0f}% 涨幅")
        high = q.get("high") or price
        if high > 0 and price >= high * 0.99:
            score += 6
        industry = q.get("industry") or ""
        peers = industry_heat.get(industry, 0) - 1 if industry else 0
        concept_peers = max((concept_heat[c] - 1 for c in ctx["conceptsOf"](code)), default=0)
        best_concept = max(ctx["conceptsOf"](code), key=lambda c: concept_heat[c], default="")
        resonance = max(peers, concept_peers)
        if resonance >= 3:
            score += 12
        elif resonance >= 2:
            score += 8
        elif resonance >= 1:
            score += 4
        if resonance >= 1:
            sector = industry if peers >= concept_peers else best_concept
            signals.append(f"板块联动：{sector} 同期 {resonance} 只异动")
            tags.append(sector)
        if len(code_events) >= 2:
            score += 5; signals.append(f"今日第 {len(code_events)} 波拉升")
        if (q.get("volumeRatio") or 0) >= 2:
            score += 5
        ratio = limit_ratio(code, q.get("name", "")) or 0.1
        room = ratio * 100 - change
        if q.get("upperLimit"):
            tags.append("已封板"); score -= 15; risks.append("已封涨停，普通委托难以成交，见「涨停接力」")
        elif room <= 2:
            score += 3; tags.append("逼近涨停")
        elif 2 <= change <= 7:
            score += 6
        elif change < 0:
            score += 1; tags.append("水下拉升")
        minute = event.get("sessionMinute", 120)
        if minute <= 60:
            score += 5; signals.append("早盘发起")
        elif minute >= 210:
            score -= 3; risks.append("尾盘拉升，次日溢价不确定")
        float_cap = q.get("floatMarketCap") or 0
        if 2e9 <= float_cap <= 3e10:
            score += 4
        elif float_cap > 1e11:
            score -= 3
        if (q.get("amount") or 0) < 1e8:
            score -= 4; risks.append("成交额不足 1 亿，流动性一般")
        history = cached_daily(code)
        features = daily_features(q, history, ctx["now"]) if history else None
        if features:
            bonus, extra_signals, extra_risks = _daily_structure_bonus(features)
            score += bonus; signals.extend(extra_signals); risks.extend(extra_risks)
        if ctx["weak"]:
            score *= 0.9
        highlights = [f"{event['time']} 起拉", f"{max(event['seconds'], 1)} 秒 +{event['rise']:.1f}%",
                      f"额速 {accel:.1f}×" if accel else "额速 —", f"承接 {max(retention, 0) * 100:.0f}%"]
        if "speed3" in metrics:
            highlights.append(f"3 分钟 {metrics['speed3']:+.2f}%")
        stop = max(event["low"] * 0.985, price * 0.93)
        results.append(_base_item(q, "surge", score, signals, risks, pivot=event["low"], stop=stop,
                                  highlights=highlights, tags=tags,
                                  extra={"surgeTime": event["time"], "surgeRise": event["rise"],
                                         "speed3": round(metrics["speed3"], 2) if "speed3" in metrics else None,
                                         "ret20": round(features["ret20"] * 100, 2) if features else None}))
    return _finalize(results, 45)

# ---------------------------------------------------------------------------
# 策略：涨停接力
# ---------------------------------------------------------------------------
def strategy_limit(ctx):
    zt, emotion = ctx["zt"], ctx["emotion"]
    pool, broken, previous = zt["pool"], zt["broken"], zt["previous"]
    sealed_by_industry = Counter(item["industry"] for item in pool.values() if item.get("industry"))
    candidates = {}
    for code, item in pool.items():
        candidates[code] = ("sealed", item)
    for code, item in broken.items():
        candidates.setdefault(code, ("broken", item))
    if ctx["live"]:
        for q in ctx["rows"]:
            code = q["code"]
            if code in candidates or q.get("suspended") or q.get("upperLimit"):
                continue
            limit_up = q.get("limitUpPrice")
            if limit_up and q.get("price", 0) >= limit_up * 0.98:
                candidates[code] = ("near", {})
    results = []
    for code, (status, item) in candidates.items():
        q = ctx["byCode"].get(code)
        if not q or not _is_tradeable_board(code, q.get("name", "")):
            continue
        if q.get("upperLimit") and status != "sealed":
            status = "sealed"
            item = pool.get(code, item)
        price = q["price"]
        signals, risks, highlights, tags = [], [], [], []
        history = cached_daily(code)
        features = daily_features(q, history, ctx["now"]) if history else None
        prev = previous.get(code)
        streak = item.get("streak") or ((prev or {}).get("prevStreak", 0) + 1 if prev else None)
        if streak is None and features is not None:
            streak = features["streak"] + 1
        streak = streak or 1
        first_time = item.get("firstTime")
        open_count = item.get("openCount", 0) or 0
        if status == "near":
            score = 22; tags.append("冲板中"); signals.append("距涨停不足 2%，仍可挂单")
        elif status == "sealed":
            score = 14; tags.append(f"{streak} 连板" if streak > 1 else "首板")
            if open_count:
                tags.append("回封"); signals.append(f"炸板 {open_count} 次后回封，分歧转一致")
        else:
            limit_up = item.get("limitUpPrice") or q.get("limitUpPrice") or price
            gap = (limit_up - price) / limit_up * 100 if limit_up else 99
            score = 10 + (6 if gap <= 2 else 0); tags.append("炸板")
            if gap <= 2:
                signals.append(f"炸板后仍在涨停价下 {gap:.1f}%，有回封可能")
            else:
                risks.append(f"炸板后回落至涨停价下 {gap:.1f}%")
        if status == "sealed":
            tags[0] = f"{streak} 连板" if streak > 1 else "首板"
        if first_time:
            if first_time <= "09:25:59":
                tags.append("一字板")
            if first_time < "10:00:00":
                score += 12; signals.append(f"{first_time[:5]} 早盘封板")
            elif first_time < "11:30:01":
                score += 8; signals.append(f"{first_time[:5]} 上午封板")
            elif first_time < "14:00:00":
                score += 4
            else:
                risks.append(f"{first_time[:5]} 尾盘封板，封板意愿偏弱")
        if open_count == 0 and status == "sealed":
            score += 6
        elif open_count >= 3:
            score -= 6; risks.append(f"炸板 {open_count} 次，分歧较大")
        elif open_count == 1:
            score += 2
        if streak == 1:
            score += 8
        elif streak == 2:
            score += 12; signals.append("2 进 3 关键位，资金最活跃")
        elif streak == 3:
            score += 8
        elif streak == 4:
            score += 4
        else:
            risks.append(f"{streak} 连板高度板，接力风险陡增")
        float_cap = item.get("floatMarketCap") or q.get("floatMarketCap") or 0
        seal = item.get("sealAmount") or 0
        if float_cap > 0 and seal > 0:
            seal_ratio = seal / float_cap * 100
            if seal_ratio >= 3:
                score += 8; signals.append(f"封单占流通市值 {seal_ratio:.1f}%，封板坚决")
            elif seal_ratio >= 1:
                score += 4
            highlights.append(f"封单 {seal / 1e8:.2f} 亿")
        turnover = item.get("turnover") or q.get("turnover")
        if "一字板" in tags:
            score -= 6; risks.append("一字板几乎无法买入")
        elif turnover is not None:
            if 3 <= turnover <= 15:
                score += 6
            elif turnover > 25:
                score -= 4; risks.append(f"换手 {turnover:.0f}% 过高，筹码松动")
        zt_industry = item.get("industry") or ""
        peers = sealed_by_industry.get(zt_industry, 0) - (1 if code in pool else 0)
        if peers >= 3:
            score += 12; signals.append(f"板块梯队：{zt_industry} 另有 {peers} 只涨停")
            tags.append(zt_industry)
        elif peers >= 1:
            score += 6; tags.append(zt_industry)
        broken_rate = emotion.get("brokenRate")
        premium = emotion.get("previousPremium")
        if broken_rate is not None:
            if broken_rate < 25:
                score += 6
            elif broken_rate > 45:
                score -= 8; risks.append(f"炸板率 {broken_rate:.0f}%，打板环境差")
        if premium is not None:
            if premium > 2:
                score += 5
            elif premium < -1:
                score -= 6; risks.append(f"昨日涨停今日平均 {premium:+.1f}%，接力亏钱效应")
        if 2e9 <= float_cap <= 1.5e10:
            score += 5
        elif float_cap > 5e10:
            score -= 4
        if features:
            if features["price"] > features["high60"]:
                score += 6; signals.append("涨停突破 60 日新高")
            if features["ret20"] > 0.6:
                score -= 10; risks.append(f"近 20 日已涨 {features['ret20'] * 100:.0f}%")
            if features["limitUps15"] >= 3 and streak == 1:
                signals.append(f"近 15 日 {features['limitUps15']} 次涨停，股性活跃")
        if ctx["weak"]:
            score *= 0.9
        if first_time:
            highlights.insert(0, f"首封 {first_time[:5]}")
        if open_count:
            highlights.append(f"炸板 {open_count} 次")
        if item.get("stat"):
            highlights.append(f"涨停统计 {item['stat']}")
        limit_up = q.get("limitUpPrice") or price
        stop = max(limit_up * 0.95, (q.get("low") or 0) * 0.99) if status != "broken" else price * 0.95
        results.append(_base_item(q, "limit", score, signals, risks, pivot=limit_up, stop=stop,
                                  highlights=highlights, tags=[t for t in tags if t],
                                  extra={"limitStreak": streak, "firstLimitTime": first_time,
                                         "limitOpenCount": open_count, "limitStatus": status,
                                         "buyable": status != "sealed" or open_count > 0}))
    return _finalize(results, 45)

# ---------------------------------------------------------------------------
# 策略：趋势突破（两段式漏斗）
# ---------------------------------------------------------------------------
def market_breadth(rows):
    """Market mood and the strongest industries from one snapshot."""
    active = [r for r in rows if not r.get("suspended") and r.get("price", 0) > 0]
    changes = [r["changePercent"] for r in active]
    up = sum(c > 0 for c in changes)
    down = sum(c < 0 for c in changes)
    up_ratio = up / max(up + down, 1)
    median_change = _median(changes)
    if up_ratio >= 0.6 and median_change > 0.3:
        regime = "强势"
    elif up_ratio <= 0.35 or median_change < -0.8:
        regime = "弱势"
    else:
        regime = "震荡"
    by_industry: dict[str, list[float]] = {}
    for r in active:
        if r.get("industry"):
            by_industry.setdefault(r["industry"], []).append(r["changePercent"])
    ranked = sorted(((name, _median(values)) for name, values in by_industry.items() if len(values) >= 8),
                    key=lambda item: item[1], reverse=True)
    strong = [name for name, change in ranked[:5] if change > 0]
    return {
        "upCount": up, "downCount": down, "flatCount": len(changes) - up - down,
        "upRatio": round(up_ratio, 4), "medianChange": round(median_change, 3), "regime": regime,
        "limitUpCount": sum(bool(r.get("upperLimit")) for r in active),
        "limitDownCount": sum(bool(r.get("lowerLimit")) for r in active),
        "strongIndustries": strong,
    }

def screen_snapshot(rows, strong_industries, limit=POTENTIAL_STAGE1_LIMIT, live=False):
    """Stage 1: score every listed stock from the live snapshot plus local speed samples."""
    picks = []
    now_ts = time.time()
    for q in rows:
        code, name, price, change = q["code"], q.get("name", ""), q.get("price", 0), q.get("changePercent", 0)
        if q.get("suspended") or price < 2 or not _is_tradeable_board(code, name):
            continue
        if q.get("upperLimit"):
            continue
        ratio = limit_ratio(code, name)
        # Fast movers are no longer cut at +7%: keep anything still 1.5 points below the limit.
        if change < -1.5 or change > ratio * 100 - 1.5:
            continue
        if (q.get("amount") or 0) < 100_000_000:
            continue
        volume_ratio, turnover = q.get("volumeRatio"), q.get("turnover")
        if volume_ratio is not None and volume_ratio < 0.9:
            continue
        if turnover is not None and not (1 <= turnover <= 25):
            continue
        score, reasons = 0.0, []
        if volume_ratio:
            score += min(max(volume_ratio - 1, 0), 3) / 3 * 20
            if volume_ratio >= 1.5:
                reasons.append(f"量比 {volume_ratio:.2f}")
        if 1 <= change <= 5:
            score += 12
        elif change > 5:
            score += 10
        elif change > 0:
            score += 6
        else:
            score += 2
        if turnover is not None:
            score += 8 if 3 <= turnover <= 12 else 3
        high, low, open_price = q.get("high"), q.get("low"), q.get("open")
        if high and low and high > low:
            position = min(max((price - low) / (high - low), 0.0), 1.0)
            score += position * 10
            if position >= 0.8 and change > 0:
                reasons.append("收于日内高位")
        if open_price and price > open_price:
            score += 4
        if q.get("industry") in strong_industries:
            score += 8
        if live:
            metrics = tick_metrics(code, q, now_ts)
            if metrics.get("rise5", 0) >= 1.5 and metrics.get("accel", 0) >= 2:
                score += 10; reasons.append(f"盘中速拉 +{metrics['rise5']:.1f}%")
        picks.append((score, reasons, q))
    picks.sort(key=lambda item: item[0], reverse=True)
    return picks[:limit]

def analyze_trend(q, history, stage1_score, stage1_reasons, strong_industries, now, weak_market, surged=None):
    f = daily_features(q, history, now)
    if not f:
        return None
    p, change = f["price"], f["change"]
    ma5, ma10, ma20, ma60 = f["ma5"], f["ma10"], f["ma20"], f["ma60"]
    score, signals, risks = 0.0, [], []
    trend_points = 0
    ma20_rising = ma20 > f["ma20Before"]
    if ma5 > ma10 > ma20 > ma60 and ma20_rising:
        trend_points = 15; signals.append("均线多头排列")
    elif p > ma20 > ma60 and ma20_rising:
        trend_points = 10; signals.append("站上上行的 20 日线")
    elif p > ma20 and ma20_rising:
        trend_points = 6; signals.append("站上 20 日线")
    score += trend_points
    if f["maSpread"] < 0.03:
        score += 10; signals.append(f"均线粘合 {f['maSpread'] * 100:.1f}%，蓄势待变")
    elif f["maSpread"] < 0.05:
        score += 5
    if f["std60"] > 0 and f["std10"] / f["std60"] < 0.65:
        score += 8; signals.append("振幅收敛，筹码趋稳")
    elif f["std60"] > 0 and f["std10"] / f["std60"] < 0.85:
        score += 4
    breakout_points, pivot = 0, None
    if p > f["high60"]:
        breakout_points, pivot = 18, f["high60"]; signals.append(f"突破 60 日高点 {f['high60']:.2f}")
    elif p > f["high20"]:
        breakout_points, pivot = 12, f["high20"]; signals.append(f"突破 20 日高点 {f['high20']:.2f}")
    elif p >= f["high60"] * 0.97:
        breakout_points = 7; signals.append(f"逼近 60 日平台上沿 {f['high60']:.2f}")
    score += breakout_points
    if trend_points == 0 and breakout_points == 0:
        return None
    amount_ratio = f["amountRatio"]
    volume_points = 0
    if amount_ratio is not None:
        if amount_ratio >= 2:
            volume_points += 12; signals.append(f"放量 {amount_ratio:.1f} 倍")
        elif amount_ratio >= 1.5:
            volume_points += 8; signals.append(f"温和放量 {amount_ratio:.1f} 倍")
        elif amount_ratio >= 1.2:
            volume_points += 4
        if f["avg20"] > 0 and f["avg5"] / f["avg20"] < 0.8 and amount_ratio >= 1.5:
            volume_points += 6; signals.append("缩量调整后放量")
    if f["downAmount"] > 0 and f["upAmount"] / f["downAmount"] > 1.5:
        volume_points += 5; signals.append("近 20 日红肥绿瘦")
    score += min(volume_points, 20)
    ret20, ret60 = f["ret20"], f["ret60"]
    if 0.05 <= ret20 <= 0.25:
        score += 8; signals.append(f"近 20 日 +{ret20 * 100:.1f}%")
    elif 0 <= ret20 < 0.05:
        score += 4
    if 0.2 <= ret60 <= 0.6 and ret20 <= 0.25:
        score += 4; signals.append("60 日相对强度靠前")
    dif, dea = f["dif"], f["dea"]
    if f["goldenCross"] and dif[-1] > 0:
        score += 10; signals.append("MACD 零轴上方金叉")
    elif f["goldenCross"]:
        score += 7; signals.append("MACD 金叉")
    elif dif[-1] > dea[-1] and dif[-1] > 0:
        score += 4
    if surged:
        score += 6; signals.append(f"盘中资金攻击 {surged}")
    if q.get("industry") in strong_industries:
        score += 6; signals.append(f"行业领涨（{q['industry']}）")
    score += min(stage1_score, 72) / 72 * 15
    signals.extend(reason for reason in stage1_reasons if reason not in signals)
    bias20 = f["bias20"]
    if bias20 > 0.15:
        score -= 15; risks.append(f"偏离 20 日线 {bias20 * 100:.0f}%，追高风险大")
    elif bias20 > 0.10:
        score -= 6; risks.append(f"偏离 20 日线 {bias20 * 100:.0f}%")
    if ret20 > 0.40:
        score -= 15; risks.append(f"近 20 日已涨 {ret20 * 100:.0f}%")
    elif f["ret5"] > 0.20:
        score -= 10; risks.append(f"近 5 日已涨 {f['ret5'] * 100:.0f}%")
    if p < ma60:
        score -= 6; risks.append("仍在 60 日线下方，上方有套牢盘")
    if amount_ratio is not None and amount_ratio > 3.5 and change < 1:
        score -= 10; risks.append("放量滞涨")
    if f["todayBar"]["high"] > 0 and (f["todayBar"]["high"] - p) / f["prevClose"] > 0.03:
        score -= 6; risks.append("冲高回落，上影线较长")
    if weak_market:
        score *= 0.85
    if pivot is None:
        pivot = ma10
    stop = max(min(pivot * 0.97, ma20 * 0.98), p * 0.92)
    highlights = [f"额比 {amount_ratio:.1f}" if amount_ratio else "额比 —", f"20日 {ret20 * 100:+.1f}%",
                  f"乖离 {bias20 * 100:+.1f}%"]
    return _base_item(q, "trend", score, signals, risks, pivot=pivot, stop=stop, highlights=highlights,
                      extra={"amountRatio": round(amount_ratio, 2) if amount_ratio is not None else None,
                             "ret20": round(ret20 * 100, 2), "bias20": round(bias20 * 100, 2)})

# ---------------------------------------------------------------------------
# 策略：强势回踩
# ---------------------------------------------------------------------------
def pullback_candidates(ctx, limit=90):
    _load_limit_history()
    today = ctx["now"].strftime("%Y%m%d")
    dates = sorted((d for d in limit_history if d < today), reverse=True)[:15]
    counts, latest = Counter(), {}
    for date in dates:
        for code in limit_history[date]:
            counts[code] += 1
            latest.setdefault(code, date)
    picks = []
    for code, count in counts.items():
        q = ctx["byCode"].get(code)
        if not q or q.get("suspended") or not _is_tradeable_board(code, q.get("name", "")):
            continue
        if not (-5 <= q.get("changePercent", 0) <= 3) or (q.get("amount") or 0) < 50_000_000:
            continue
        picks.append((count, latest[code], q))
    picks.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [q for _, _, q in picks[:limit]]

def analyze_pullback(q, history, ctx):
    f = daily_features(q, history, ctx["now"])
    if not f:
        return None
    p = f["price"]
    peak = f["high20"]
    drawdown = (peak - p) / peak if peak > 0 else 0
    ma10, ma20 = f["ma10"], f["ma20"]
    if not (0.06 <= drawdown <= 0.28) or p < ma20 * 0.97 or f["limitUps15"] == 0:
        return None
    base = min(b["close"] for b in f["prior"][-30:-10]) if len(f["prior"]) >= 30 else f["low20"]
    if base <= 0 or peak / base < 1.2:
        return None
    score, signals, risks = 0.0, [], []
    signals.append(f"近 15 日 {f['limitUps15']} 次涨停，前期涨幅 {(peak / base - 1) * 100:.0f}%")
    score += 14 if f["limitUps15"] >= 2 else 8
    dist10, dist20 = p / ma10 - 1, p / ma20 - 1
    support = None
    if abs(dist10) <= 0.025:
        score += 18; support = ma10; signals.append(f"回踩 10 日线 {ma10:.2f}")
    elif abs(dist20) <= 0.025:
        score += 16; support = ma20; signals.append(f"回踩 20 日线 {ma20:.2f}")
    elif p > ma10:
        score += 6
    if 0.10 <= drawdown <= 0.20:
        score += 10
    elif drawdown < 0.10:
        score += 5
    signals.append(f"自高点回撤 {drawdown * 100:.0f}%")
    if f["avg20"] > 0 and f["avg5"] / f["avg20"] < 0.85:
        score += 12; signals.append("回调缩量，抛压减轻")
    if f["amountRatio"] is not None and f["amountRatio"] < 0.9:
        score += 5
    if ma20 > f["ma20Before"]:
        score += 10; signals.append("20 日线仍在上行")
    today = f["todayBar"]
    if today["low"] > 0 and (p - today["low"]) / f["prevClose"] >= 0.02:
        score += 6; signals.append("盘中下探后拉回，下影承接")
    if q.get("industry") in ctx["breadth"]["strongIndustries"]:
        score += 6; signals.append(f"所属行业仍强（{q['industry']}）")
    if f["amountRatio"] is not None and f["amountRatio"] > 1.5 and f["change"] < -2:
        score -= 12; risks.append("放量下跌，可能是出货而非洗盘")
    if p < ma20:
        score -= 5; risks.append("略破 20 日线，需尽快收回")
    if drawdown > 0.22:
        risks.append(f"回撤 {drawdown * 100:.0f}% 偏深，强势可能已结束")
    if ctx["weak"]:
        score *= 0.9
    support = support or ma20
    stop = max(support * 0.96, p * 0.9)
    highlights = [f"回撤 {drawdown * 100:.0f}%", f"距10日线 {dist10 * 100:+.1f}%", f"距20日线 {dist20 * 100:+.1f}%",
                  f"5/20日额 {f['avg5'] / f['avg20']:.2f}" if f["avg20"] else "5/20日额 —"]
    return _base_item(q, "pullback", score, signals, risks, pivot=support, stop=stop, highlights=highlights,
                      extra={"ret20": round(f["ret20"] * 100, 2), "bias20": round(f["bias20"] * 100, 2),
                             "amountRatio": round(f["amountRatio"], 2) if f["amountRatio"] else None})

# ---------------------------------------------------------------------------
# 策略：板块龙头
# ---------------------------------------------------------------------------
def sector_heat(ctx):
    groups: dict[tuple[str, str], list[dict]] = {}
    for q in ctx["rows"]:
        if q.get("suspended") or q.get("price", 0) <= 0:
            continue
        if q.get("industry"):
            groups.setdefault(("行业", q["industry"]), []).append(q)
        for concept in ctx["conceptsOf"](q["code"]):
            groups.setdefault(("题材", concept), []).append(q)
    ranked = []
    for (kind, name), members in groups.items():
        if len(members) < (8 if kind == "行业" else 6) or (kind == "题材" and len(members) > 400):
            continue
        changes = sorted((m.get("changePercent", 0) for m in members), reverse=True)
        limit_ups = sum(bool(m.get("upperLimit")) for m in members)
        heat = _median(changes) * 4 + _mean(changes[:5]) + limit_ups * 1.5
        ranked.append({"kind": kind, "name": name, "heat": heat, "median": _median(changes),
                       "limitUps": limit_ups, "members": members})
    ranked.sort(key=lambda item: item["heat"], reverse=True)
    industries = [s for s in ranked if s["kind"] == "行业" and (s["median"] > 0 or s["limitUps"] >= 2)][:5]
    concepts = [s for s in ranked if s["kind"] == "题材" and (s["median"] > 0 or s["limitUps"] >= 2)][:6]
    return industries, concepts

def strategy_leader(ctx):
    industries, concepts = sector_heat(ctx)
    zt_pool = ctx["zt"]["pool"]
    best: dict[str, dict] = {}
    now_ts = time.time()
    for rank_group in (industries, concepts):
        for rank, sector in enumerate(rank_group):
            members = [m for m in sector["members"] if _is_tradeable_board(m["code"], m.get("name", ""))
                       and (m.get("amount") or 0) >= 50_000_000]
            if len(members) < 3:
                continue
            by_change = sorted(members, key=lambda m: m.get("changePercent", 0), reverse=True)
            by_amount = sorted(members, key=lambda m: m.get("amount") or 0, reverse=True)
            change_rank = {m["code"]: i for i, m in enumerate(by_change)}
            amount_rank = {m["code"]: i for i, m in enumerate(by_amount)}
            scored = []
            for m in by_change[:12]:
                code = m["code"]
                n = len(members)
                leader = (1 - change_rank[code] / n) * 40 + (1 - amount_rank[code] / n) * 25
                first_time = (zt_pool.get(code) or {}).get("firstTime")
                if m.get("upperLimit"):
                    leader += 15
                    if first_time:
                        leader += 10 if first_time < "10:00:00" else (6 if first_time < "11:30:01" else 2)
                if ctx["live"]:
                    rise = tick_metrics(code, m, now_ts).get("rise5", 0)
                    leader += min(max(rise, 0) / 3, 1) * 10
                scored.append((leader, m, first_time))
            scored.sort(key=lambda item: item[0], reverse=True)
            for leader, m, first_time in scored[:2]:
                code = m["code"]
                score = max(35 - rank * 5, 10) + leader * 0.55
                signals = [f"{sector['kind']}「{sector['name']}」热度第 {rank + 1}（中位 {sector['median']:+.2f}%，涨停 {sector['limitUps']} 只）",
                           f"板块内涨幅第 {change_rank[code] + 1}、成交额第 {amount_rank[code] + 1}"]
                risks, tags = [], [sector["name"]]
                if m.get("upperLimit"):
                    tags.append("已封板")
                    signals.append(f"{first_time[:5]} 封板" if first_time else "已封涨停")
                features = None
                history = cached_daily(code)
                if history:
                    features = daily_features(m, history, ctx["now"])
                if features:
                    bonus, extra_signals, extra_risks = _daily_structure_bonus(features)
                    score += min(bonus, 10); signals.extend(extra_signals); risks.extend(extra_risks)
                if ctx["weak"]:
                    score *= 0.9
                price = m["price"]
                stop = max((m.get("low") or price) * 0.98, price * 0.92)
                item = _base_item(m, "leader", score, signals, risks, pivot=m.get("open") or price, stop=stop,
                                  highlights=[sector["name"], f"板内涨幅 #{change_rank[code] + 1}",
                                              f"板内成交 #{amount_rank[code] + 1}"],
                                  tags=tags, extra={"sector": sector["name"],
                                                    "ret20": round(features["ret20"] * 100, 2) if features else None})
                if code not in best or item["score"] > best[code]["score"]:
                    best[code] = item
    return _finalize(list(best.values()), 45)

# ---------------------------------------------------------------------------
# 策略：尾盘潜伏
# ---------------------------------------------------------------------------
def strategy_tail(ctx):
    now = ctx["now"]
    minute = now.hour * 60 + now.minute
    results = []
    for q in ctx["rows"]:
        code, change, price = q["code"], q.get("changePercent", 0), q.get("price", 0)
        if q.get("suspended") or q.get("upperLimit") or price < 2 or not _is_tradeable_board(code, q.get("name", "")):
            continue
        if not (2.5 <= change <= 6):
            continue
        volume_ratio, turnover, float_cap = q.get("volumeRatio"), q.get("turnover"), q.get("floatMarketCap") or 0
        if volume_ratio is None or volume_ratio < 1.2 or turnover is None or not (3 <= turnover <= 12):
            continue
        if not (3e9 <= float_cap <= 3e10):
            continue
        high, low = q.get("high") or price, q.get("low") or price
        position = (price - low) / (high - low) if high > low else 1.0
        if position < 0.75:
            continue
        signals, risks = [], []
        score = 20 + min(volume_ratio - 1.2, 1.8) / 1.8 * 12 + position * 10
        if 5 <= turnover <= 10:
            score += 6
        marks = day_mark_series(code)
        afternoon = [price_mark for slot, price_mark in marks if slot >= 24]
        if len(afternoon) >= 4:
            rises = sum(1 for a, b in zip(afternoon, afternoon[1:]) if b >= a)
            steadiness = rises / (len(afternoon) - 1)
            if steadiness >= 0.7 and afternoon[-1] > afternoon[0]:
                score += 14; signals.append("午后 5 分钟线稳步走高")
            elif afternoon[-1] < max(afternoon) * 0.99:
                score -= 6; risks.append("午后冲高回落")
        if q.get("industry") in ctx["breadth"]["strongIndustries"]:
            score += 6; signals.append(f"行业走强（{q['industry']}）")
        history = cached_daily(code)
        features = daily_features(q, history, now) if history else None
        if features:
            if features["ma5"] > features["ma10"] > features["ma20"]:
                score += 10; signals.append("日线短均线多头")
            if features["ret20"] > 0.25:
                score -= 10; risks.append(f"近 20 日已涨 {features['ret20'] * 100:.0f}%")
            if features["streak"] > 0:
                score -= 6; risks.append("昨日涨停，次日溢价已透支")
            if features["avg20"] > 0 and features["avg5"] > features["avg20"]:
                score += 4
        signals.insert(0, f"涨 {change:.1f}%、量比 {volume_ratio:.1f}、换手 {turnover:.1f}%，收在日内 {position * 100:.0f}% 位置")
        if ctx["weak"]:
            score *= 0.9
        tags = [] if minute >= 870 or minute < 570 else ["预览"]
        results.append(_base_item(q, "tail", score, signals, risks, pivot=low + (high - low) * 0.5,
                                  stop=price * 0.95,
                                  highlights=[f"量比 {volume_ratio:.2f}", f"换手 {turnover:.1f}%",
                                              f"流通 {float_cap / 1e8:.0f} 亿", f"日内位置 {position * 100:.0f}%"],
                                  tags=tags,
                                  extra={"ret20": round(features["ret20"] * 100, 2) if features else None}))
    return _finalize(results, 50)

# ---------------------------------------------------------------------------
# 策略：尾盘隔夜（14:50 买入，次日冲高卖出）
# ---------------------------------------------------------------------------
# Logistic models fitted on 1,490 random A-shares, 2026-01 → 2026-11 daily bars
# (165k stock-days, out-of-sample from 2026-07-24). Target: next-day high over
# today's close ≥ +3% / ≥ +5%. Only features available in the 14:50 snapshot
# are used — adding daily-chart features did not improve the hit rate.
OVERNIGHT_FEATS = ["limitPct", "pos", "upper", "vwapDev", "ampL", "trL", "amtRatioL", "lnAmt", "gem"]
OVERNIGHT_CLIP = {"limitPct": (-0.8019, 0.6801), "pos": (0.0, 1.0), "upper": (0.0, 10.0885),
                  "vwapDev": (-5.7016, 3.7886), "ampL": (0.0685, 2.6749), "trL": (-1.273, 3.0227),
                  "amtRatioL": (-0.8484, 1.2074), "lnAmt": (7.7112, 9.8854), "gem": (0.0, 1.0)}
OVERNIGHT_MU = [-0.02299, 0.45772, 2.54109, -0.85013, 1.39985, 1.02516, -0.03806, 8.40879, 0.37384]
OVERNIGHT_SD = [0.25786, 0.29975, 2.11196, 1.71071, 0.5524, 0.87328, 0.38893, 0.51185, 0.48382]
OVERNIGHT_W3 = [-1.05845, -0.00627, -0.05349, -0.02967, 0.04499, 0.51576, 0.13095, -0.16436, 0.16597, 0.06625]
OVERNIGHT_W5 = [-2.08604, 0.00571, 0.00745, 0.03622, 0.07755, 0.48858, 0.20956, -0.16658, 0.22457, 0.04491]
# Ridge model of next-open gap relative to the day's median: used as a small
# penalty so that picks with the worst expected gap-down are avoided.
OVERNIGHT_WGAP = [0.0033, 0.03033, -0.05259, -0.04161, -0.02969, 0.0223, -0.08234, -0.05187, -0.05035, 0.04183]
# Out-of-sample the top decile's predicted probability ran ~17% above the
# realised hit rate, so displayed probabilities are shrunk accordingly.
OVERNIGHT_CALIBRATION = 0.83
OVERNIGHT_PER_BOARD = 15
OVERNIGHT_TAKE_PROFIT = 3.0
OVERNIGHT_STOP = 3.0

def _overnight_board(code):
    return "创业科创" if code.startswith(("300", "301", "688", "689")) else "主板"

def overnight_features(q, now):
    price, prev_close = q.get("price") or 0, q.get("prevClose")
    change = q.get("changePercent") or 0
    if not prev_close or prev_close <= 0:
        prev_close = price / (1 + change / 100) if change > -100 else 0
    high, low = q.get("high") or price, q.get("low") or price
    if price <= 0 or prev_close <= 0:
        return None
    ratio = limit_ratio(q["code"], q.get("name", "")) or 0.1
    fraction = _volume_fraction(now)
    amount = q.get("amount") or 0
    full_amount = amount / fraction if fraction > 0 else amount
    volume = q.get("volume") or 0
    vwap = None
    for scale in (100, 1):
        candidate = amount / (volume * scale) if volume else None
        if candidate and low * 0.97 <= candidate <= high * 1.03:
            vwap = candidate
            break
    turnover = (q.get("turnover") or 0) / fraction if q.get("turnover") is not None else None
    volume_ratio = q.get("volumeRatio")
    raw = {
        "limitPct": change / (ratio * 100),
        "pos": (price - low) / (high - low) if high > low else 1.0,
        "upper": (high - price) / prev_close * 100,
        "vwapDev": (price / vwap - 1) * 100 if vwap else 0.0,
        "ampL": math.log(max((high - low) / prev_close * 100, 0.3)),
        "trL": math.log(max(turnover, 0.2)) if turnover is not None else 1.02516,
        "amtRatioL": math.log(min(max(volume_ratio, 0.1), 20)) if volume_ratio else -0.03806,
        "lnAmt": math.log10(max(full_amount, 1)),
        "gem": 1.0 if ratio >= 0.2 else 0.0,
    }
    return raw, {"vwap": vwap, "turnover": turnover, "fullAmount": full_amount,
                 "amplitude": (high - low) / prev_close * 100, "prevClose": prev_close}

def overnight_scores(raw):
    z = [1.0]
    for name, mu, sd in zip(OVERNIGHT_FEATS, OVERNIGHT_MU, OVERNIGHT_SD):
        lo, hi = OVERNIGHT_CLIP[name]
        z.append((min(max(raw[name], lo), hi) - mu) / sd)
    def logistic(weights):
        return 1 / (1 + math.exp(-sum(w * x for w, x in zip(weights, z))))
    gap = sum(w * x for w, x in zip(OVERNIGHT_WGAP, z))
    return (logistic(OVERNIGHT_W3) * OVERNIGHT_CALIBRATION, logistic(OVERNIGHT_W5) * OVERNIGHT_CALIBRATION, gap)

ohlc_lock = threading.Lock()
ohlc_cache = {"at": 0.0, "rows": {}}

def eastmoney_ohlc_snapshot(max_age=15):
    """High / low / open / amount / volume for every A-share from Eastmoney's
    paged list API. The Tencent snapshot used for quotes has no high / low and
    estimates the traded amount, which the 尾盘隔夜 model needs."""
    with ohlc_lock:
        if time.time() - ohlc_cache["at"] < max_age and ohlc_cache["rows"]:
            return ohlc_cache["rows"]
    import requests
    headers = {"User-Agent": "Mozilla/5.0", "Referer": "https://quote.eastmoney.com/"}
    url = ("https://push2.eastmoney.com/api/qt/clist/get?pn={pn}&pz=100&po=1&np=1&fltt=2&invt=2&fid=f12"
           "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=f2,f3,f5,f6,f8,f10,f12,f15,f16,f17,f18")

    def page(pn):
        for attempt in range(2):
            try:
                data = requests.get(url.format(pn=pn), headers=headers, timeout=6).json().get("data") or {}
                return data.get("diff") or [], data.get("total") or 0
            except Exception:
                time.sleep(0.3 * (attempt + 1))
        return [], 0

    first, total = page(1)
    pages = max(1, math.ceil(total / 100)) if total else 60
    with ThreadPoolExecutor(max_workers=12) as pool:
        diffs = [first] + [rows for rows, _ in pool.map(page, range(2, pages + 1))]

    def num(value):
        try:
            parsed = float(value)
            return parsed if math.isfinite(parsed) and parsed > 0 else None
        except (TypeError, ValueError):
            return None
    rows = {}
    for diff in diffs:
        for item in diff:
            code = str(item.get("f12", "")).zfill(6)
            if num(item.get("f2")) is None:
                continue
            rows[code] = {"price": num(item.get("f2")), "high": num(item.get("f15")), "low": num(item.get("f16")), "open": num(item.get("f17")),
                          "prevClose": num(item.get("f18")), "amount": num(item.get("f6")), "volume": num(item.get("f5")),
                          "turnover": num(item.get("f8")), "volumeRatio": num(item.get("f10"))}
    if len(rows) > 1000:
        with ohlc_lock:
            ohlc_cache.update(at=time.time(), rows=rows)
    else:
        print(f"Eastmoney OHLC snapshot incomplete: {len(rows)} rows", flush=True)
    return rows or ohlc_cache["rows"]

def strategy_overnight(ctx):
    now = ctx["now"]
    minute = now.hour * 60 + now.minute
    preview = 570 <= minute < 890 and now.weekday() < 5
    by_board: dict[str, list] = {"主板": [], "创业科创": []}
    try:
        ohlc = eastmoney_ohlc_snapshot()
    except Exception as exc:
        print(f"Eastmoney OHLC snapshot failed: {exc}", flush=True)
        ohlc = {}
    for base in ctx["rows"]:
        extra = ohlc.get(base["code"])
        if extra:
            q = dict(base)
            for key, value in extra.items():
                if value is not None and key != "price":
                    q[key] = value
        else:
            q = base
        if not q.get("high") or not q.get("low"):
            continue
        code, price = q["code"], q.get("price", 0)
        if (q.get("suspended") or q.get("upperLimit") or q.get("lowerLimit") or price < 2
                or not _is_tradeable_board(code, q.get("name", ""))):
            continue
        limit_up = q.get("limitUpPrice")
        if limit_up and price >= limit_up - 0.011:
            continue
        computed = overnight_features(q, now)
        if not computed:
            continue
        raw, info = computed
        if info["fullAmount"] < 5e7:
            continue
        p3, p5, gap = overnight_scores(raw)
        rank = p5 + 0.1 * gap
        by_board[_overnight_board(code)].append((rank, p3, p5, gap, raw, info, q))
    results = []
    for board, entries in by_board.items():
        entries.sort(key=lambda entry: entry[0], reverse=True)
        for position, (rank, p3, p5, gap, raw, info, q) in enumerate(entries[:OVERNIGHT_PER_BOARD], start=1):
            price, change = q["price"], q.get("changePercent", 0)
            score = 100 * (0.5 * min(p3 / 0.6, 1) + 0.5 * min(p5 / 0.4, 1))
            amplitude, turnover = info["amplitude"], info["turnover"]
            signals = [f"次日盘中冲高 ≥3% 概率约 {p3 * 100:.0f}%，≥5% 约 {p5 * 100:.0f}%（全市场平均约 25% / 12%）",
                       f"{board}第 {position} 名：振幅 {amplitude:.1f}%、换手 {turnover:.1f}%、成交 {_fmt_yuan(info['fullAmount'])}（全天折算）"
                       if turnover is not None else f"{board}第 {position} 名：振幅 {amplitude:.1f}%"]
            if raw["upper"] >= 3:
                signals.append(f"上影 {raw['upper']:.1f}%：盘中资金试过拉升，次日再冲概率更高")
            if raw["vwapDev"] <= 0:
                signals.append("现价在分时均价线下方，没有尾盘追高")
            risks = ["高波动股次日开盘平均低开约 1%：不要开盘市价卖，挂止盈单等冲高"]
            if raw["vwapDev"] > 1.5:
                risks.append(f"高于分时均价 {raw['vwapDev']:.1f}%，尾盘追高，次日低开概率大")
            if raw["pos"] > 0.9 and change > 3:
                risks.append("收在日内最高附近，回测显示次日开盘更弱")
            if gap < -0.4:
                risks.append("隔夜模型估计其低开幅度在候选中偏大")
            if ctx["weak"]:
                risks.append("今日市场弱势")
            take_profit = _round_price(price * (1 + OVERNIGHT_TAKE_PROFIT / 100))
            stop = _round_price(price * (1 - OVERNIGHT_STOP / 100))
            highlights = [f"冲高≥3% {p3 * 100:.0f}%", f"冲高≥5% {p5 * 100:.0f}%", f"止盈 {take_profit:.2f}",
                          f"振幅 {amplitude:.1f}%"]
            tags = [board] + (["预览"] if preview else [])
            results.append(_base_item(q, "overnight", score, signals, risks, pivot=take_profit, stop=stop,
                                      highlights=highlights, tags=tags,
                                      extra={"pHi3": round(p3 * 100, 1), "pHi5": round(p5 * 100, 1),
                                             "takeProfit": take_profit, "board": board,
                                             "gapRisk": round(gap, 3), "boardRank": position}))
    results.sort(key=lambda item: (item.get("pHi5") or 0), reverse=True)
    return results

def _finalize(results, min_score):
    results = [item for item in results if item["score"] >= min_score]
    results.sort(key=lambda item: (item["score"], item["changePercent"]), reverse=True)
    return results[:POTENTIAL_RESULT_LIMIT]

def combine_lists(lists):
    merged: dict[str, dict] = {}
    for strategy, items in lists.items():
        for item in items:
            current = merged.get(item["code"])
            if current is None:
                merged[item["code"]] = dict(item, strategies=[strategy], baseScore=item["score"])
                continue
            current["strategies"].append(strategy)
            if item["score"] > current["baseScore"]:
                keep = current["strategies"]
                merged[item["code"]] = dict(item, strategies=keep, baseScore=item["score"])
    combined = []
    for item in merged.values():
        bonus = 6 * (len(item["strategies"]) - 1)
        score = _clamp_score(item["baseScore"] + bonus)
        titles = [STRATEGY_TITLES.get(s, s) for s in item["strategies"]]
        signals = list(item["signals"])
        if len(titles) > 1:
            signals.insert(0, "多策略共振：" + "、".join(titles))
        entry = dict(item, score=score, grade=_grade(score), signals=signals,
                     tags=titles + [t for t in item.get("tags", []) if t not in titles])
        entry.pop("baseScore", None)
        combined.append(entry)
    combined.sort(key=lambda item: (item["score"], len(item["strategies"])), reverse=True)
    return combined[:POTENTIAL_RESULT_LIMIT]

# ---------------------------------------------------------------------------
# 调度
# ---------------------------------------------------------------------------
potential_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="potential-scan")
potential_lock = threading.Lock()
potential_state = {
    "updatedAt": 0.0, "lastAttempt": 0.0, "scanning": False, "progress": 0, "total": 0, "phase": "",
    "provider": "", "lists": {"trend": [], "pullback": []}, "error": "", "sessionDate": "",
}
live_cache = {"at": 0.0, "provider": "", "payload": None}
live_cache_lock = threading.Lock()

def _market_rows(provider):
    rows = cache_by_provider.get(provider)
    if not rows:
        rows = next((value for value in cache_by_provider.values() if value), None)
    if not rows:
        rows, *_ = get_market(provider)
    return rows

def build_context(provider):
    rows = _market_rows(provider)
    with classification_lock:
        industries = dict(industry_by_code)
        concepts = dict(concepts_by_code)
    useful_cache: dict[str, list[str]] = {}

    def concepts_of(code):
        cached = useful_cache.get(code)
        if cached is None:
            cached = useful_cache[code] = _useful_concepts(sorted(concepts.get(code, ())))
        return cached

    rows = [dict(row, industry=industries.get(row["code"], "")) for row in rows]
    by_code = {row["code"]: row for row in rows}
    breadth = market_breadth(rows)
    now = datetime.now(SHANGHAI_TZ)
    zt = zt_snapshot()
    emotion = limit_emotion(zt) if zt["date"] else {}
    return {
        "rows": rows, "byCode": by_code, "breadth": breadth, "now": now,
        "live": _session_minute(now) is not None, "weak": breadth["regime"] == "弱势",
        "industryOf": lambda code: industries.get(code, ""), "conceptsOf": concepts_of,
        "zt": zt, "emotion": emotion, "surgeEvents": surge_events_snapshot(),
    }

def _run_potential_scan(provider):
    started = time.monotonic()
    fetched = 0
    try:
        ctx = build_context(provider)
        stage1 = screen_snapshot(ctx["rows"], ctx["breadth"]["strongIndustries"], live=ctx["live"])
        pullback_pool = pullback_candidates(ctx)
        live_lists = {
            "surge": strategy_surge(ctx), "limit": strategy_limit(ctx),
            "leader": strategy_leader(ctx), "tail": strategy_tail(ctx),
        }
        prefetch = []
        for items in live_lists.values():
            prefetch.extend(item["code"] for item in items[:25])
        order, seen = [], set()
        for code in prefetch + [q["code"] for _, _, q in stage1] + [q["code"] for q in pullback_pool]:
            if code not in seen:
                seen.add(code); order.append(code)
        with potential_lock:
            potential_state.update(progress=0, total=len(order), phase="拉取日线")
        surge_by_code = {item["code"]: item.get("highlights", [""])[1] if len(item.get("highlights", [])) > 1 else "" for item in live_lists["surge"]}
        for index, code in enumerate(order, start=1):
            if cached_daily(code) is None and fetched < POTENTIAL_MAX_FETCHES:
                try:
                    fetch_daily_rows(code, "year")
                    fetched += 1
                    time.sleep(POTENTIAL_HISTORY_INTERVAL)
                except Exception as exc:
                    print(f"Potential scan daily fetch skipped {code}: {exc}", flush=True)
            with potential_lock:
                potential_state["progress"] = index
        trend, pullback = [], []
        weak = ctx["weak"]
        for stage1_score, reasons, q in stage1:
            history = cached_daily(q["code"])
            if not history:
                continue
            try:
                item = analyze_trend(q, history, stage1_score, reasons, ctx["breadth"]["strongIndustries"],
                                     ctx["now"], weak, surge_by_code.get(q["code"]))
                if item:
                    trend.append(item)
            except Exception as exc:
                print(f"Trend analysis skipped {q['code']}: {exc}", flush=True)
        for q in pullback_pool:
            history = cached_daily(q["code"])
            if not history:
                continue
            try:
                item = analyze_pullback(q, history, ctx)
                if item:
                    pullback.append(item)
            except Exception as exc:
                print(f"Pullback analysis skipped {q['code']}: {exc}", flush=True)
        with potential_lock:
            potential_state.update(
                updatedAt=time.time(), error="", phase="", sessionDate=ctx["now"].strftime("%Y-%m-%d"),
                lists={"trend": _finalize(trend, POTENTIAL_MIN_SCORE), "pullback": _finalize(pullback, 50)})
        with live_cache_lock:
            live_cache["at"] = 0.0
        _save_daily_disk_cache()
        print(f"Potential scan done provider={provider}: stage1={len(stage1)}, pullbackPool={len(pullback_pool)}, "
              f"trend={len(trend)}, pullback={len(pullback)}, fetched={fetched}, regime={ctx['breadth']['regime']}, "
              f"elapsed={time.monotonic() - started:.1f}s", flush=True)
    except Exception as exc:
        with potential_lock:
            potential_state["error"] = str(exc)
        print(f"Potential scan failed provider={provider}: {exc}", flush=True)
    finally:
        with potential_lock:
            potential_state["scanning"] = False
            potential_state["phase"] = ""

def ensure_potential_scan(provider, force=False):
    now = datetime.now(SHANGHAI_TZ)
    ensure_zt()
    with potential_lock:
        if potential_state["scanning"]:
            return
        age = time.time() - potential_state["updatedAt"]
        fresh = age < _potential_ttl(now) and potential_state["provider"] == provider
        retry_wait = time.time() - potential_state["lastAttempt"] < 60
        if (fresh and not force) or (retry_wait and not force):
            return
        potential_state.update(scanning=True, lastAttempt=time.time(), provider=provider, progress=0, total=0)
    potential_executor.submit(_run_potential_scan, provider)

def _overnight_note():
    now = datetime.now(SHANGHAI_TZ)
    minute = now.hour * 60 + now.minute
    if now.weekday() >= 5:
        return "休市：显示最近收盘时的排序，仅供参考"
    if 570 <= minute < 890:
        return "14:50 锁定推荐，此前为预览（排序会随行情变化）"
    if 890 <= minute < 900:
        return "推荐已锁定：14:50–14:57 买入，次日挂 +3% 止盈"
    if minute >= 900:
        return "已收盘：按收盘价排序，次日早盘冲高卖出"
    return "开盘前：显示上一交易日收盘排序"

def potential_payload(provider="auto"):
    with live_cache_lock:
        cached = live_cache["payload"]
        if cached and live_cache["provider"] == provider and time.time() - live_cache["at"] < LIVE_LIST_TTL:
            live = cached
        else:
            live = None
    if live is None:
        ctx = build_context(provider)
        live = {
            "market": ctx["breadth"], "emotion": ctx["emotion"] or None,
            "lists": {"surge": strategy_surge(ctx), "limit": strategy_limit(ctx),
                      "leader": strategy_leader(ctx), "tail": strategy_tail(ctx),
                      "overnight": strategy_overnight(ctx)},
            "live": ctx["live"],
        }
        with live_cache_lock:
            live_cache.update(at=time.time(), provider=provider, payload=live)
    with potential_lock:
        state = dict(potential_state)
    lists = dict(live["lists"])
    lists.update(state["lists"])
    # 尾盘隔夜 has a different holding horizon (one night), so it is not merged into 综合.
    lists["all"] = combine_lists({key: value for key, value in lists.items() if key not in ("all", "overnight")})
    notes = {
        "surge": None if live["live"] else "非交易时段：显示今日已记录的速拉事件（以收盘价计算承接）",
        "limit": None if live["emotion"] else "涨停池加载中…",
        "pullback": None if lists["pullback"] or state["updatedAt"] else "强势股池与日线首次加载中，需要 1–3 分钟",
        "trend": None if state["updatedAt"] else "日线复核中，首次需要 1–3 分钟",
        "tail": "14:30 前为预览，尾盘结果更有效" if live["live"] and datetime.now(SHANGHAI_TZ).hour * 60 + datetime.now(SHANGHAI_TZ).minute < 870 else None,
        "overnight": _overnight_note(),
    }
    strategies = [dict(meta, count=len(lists.get(meta["id"], [])), note=notes.get(meta["id"])) for meta in STRATEGY_META]
    updated = state["updatedAt"]
    return {
        "updatedAt": datetime.fromtimestamp(updated, SHANGHAI_TZ).isoformat(timespec="seconds") if updated else None,
        "liveUpdatedAt": datetime.now(SHANGHAI_TZ).isoformat(timespec="seconds"),
        "scanning": state["scanning"], "progress": state["progress"], "total": state["total"],
        "phase": state["phase"] or None,
        "market": live["market"], "emotion": live["emotion"],
        "strategies": strategies, "lists": lists, "stocks": lists["all"],
        "error": state["error"] or None,
    }


# ---------------------------------------------------------------------------
# 个股量化画像与资讯（详情窗口侧栏）
# ---------------------------------------------------------------------------
news_cache: dict[str, tuple[float, list]] = {}
news_lock = threading.Lock()
NEWS_TTL = 10 * 60

def _fmt_pct(value, digits=2):
    return f"{value:+.{digits}f}%" if value is not None else "—"

def _fmt_yuan(value):
    if value is None:
        return "—"
    magnitude = abs(value)
    text = f"{magnitude / 1e8:.2f} 亿" if magnitude >= 1e8 else (f"{magnitude / 1e4:.0f} 万" if magnitude >= 1e4 else f"{magnitude:.0f} 元")
    return ("-" if value < 0 else "") + text

def _fmt_price(value):
    return f"{value:.2f}" if value else "—"

def _tone(value, neutral=0.0):
    if value is None:
        return "neutral"
    return "up" if value > neutral else ("down" if value < neutral else "neutral")

def stock_insight(code, provider="auto"):
    rows = _market_rows(provider)
    base = next((row for row in rows if row["code"] == code), None)
    if base is None:
        raise ValueError(f"行情中没有 {code}")
    with classification_lock:
        industry = industry_by_code.get(code, "")
        concepts = _useful_concepts(sorted(concepts_by_code.get(code, ())))
    q = dict(base, industry=industry)
    now = datetime.now(SHANGHAI_TZ)
    groups = []

    def item(label, value, tone="neutral", hint=None):
        entry = {"label": label, "value": value, "tone": tone}
        if hint:
            entry["hint"] = hint
        return entry

    price = q.get("price") or 0
    high, low, prev_close = q.get("high"), q.get("low"), q.get("prevClose")
    position = (price - low) / (high - low) * 100 if high and low and high > low else None
    amplitude = (high - low) / prev_close * 100 if high and low and prev_close else None
    groups.append({"title": "当日行情", "items": [
        item("涨跌幅", _fmt_pct(q.get("changePercent")), _tone(q.get("changePercent"))),
        item("今开 / 昨收", f"{_fmt_price(q.get('open'))} / {_fmt_price(prev_close)}"),
        item("最高 / 最低", f"{_fmt_price(high)} / {_fmt_price(low)}"),
        item("振幅", f"{amplitude:.2f}%" if amplitude is not None else "—"),
        item("日内位置", f"{position:.0f}%" if position is not None else "—", "up" if (position or 0) >= 80 else "neutral", "现价在今日高低点区间中的位置"),
        item("成交额", _fmt_yuan(q.get("amount"))),
        item("量比", f"{q['volumeRatio']:.2f}" if q.get("volumeRatio") is not None else "—", _tone(q.get("volumeRatio"), 1.5)),
        item("换手率", f"{q['turnover']:.2f}%" if q.get("turnover") is not None else "—"),
        item("流通市值", _fmt_yuan(q.get("floatMarketCap"))),
        item("涨停价", f"{q['limitUpPrice']:.2f}" if q.get("limitUpPrice") else "—"),
    ]})

    metrics = tick_metrics(code, q) if _session_minute(now) is not None else {}
    events = surge_events_snapshot().get(code, [])
    intraday = [
        item("1 分钟涨速", _fmt_pct(metrics.get("speed1")), _tone(metrics.get("speed1"))),
        item("3 分钟涨速", _fmt_pct(metrics.get("speed3")), _tone(metrics.get("speed3"))),
        item("5 分钟涨速", _fmt_pct(metrics.get("speed5")), _tone(metrics.get("speed5"))),
        item("5 分钟低点拉升", _fmt_pct(metrics.get("rise5")), _tone(metrics.get("rise5"))),
        item("近 3 分钟额速", f"{metrics['accel']:.1f}×" if metrics.get("accel") is not None else "—", _tone(metrics.get("accel"), 2), "近 3 分钟每分钟成交额 / 全天平均"),
        item("今日速拉", f"{len(events)} 次" if events else "无", "up" if events else "neutral"),
    ]
    for event in events[-4:]:
        intraday.append(item(f"{event['time']} 速拉", f"{event['seconds']} 秒 +{event['rise']:.1f}%，额速 {event.get('accel', 0):.1f}×", "up"))
    groups.append({"title": "盘中速度（本机逐快照）", "items": intraday})

    zt = zt_snapshot()
    limit_info = zt["pool"].get(code) or zt["broken"].get(code)
    previous = zt["previous"].get(code)
    if limit_info or previous:
        limit_items = []
        if limit_info:
            status = "封板" if code in zt["pool"] else "炸板"
            limit_items += [item("状态", status, "up" if status == "封板" else "neutral"),
                            item("首次封板", limit_info.get("firstTime") or "—"),
                            item("炸板次数", str(limit_info.get("openCount") or 0)),
                            item("连板", f"{limit_info.get('streak')} 板" if limit_info.get("streak") else "—", "up"),
                            item("封单", _fmt_yuan(limit_info.get("sealAmount")) if limit_info.get("sealAmount") else "—"),
                            item("涨停统计", limit_info.get("stat") or "—", hint="近期涨停天数 / 统计天数")]
        if previous:
            limit_items.append(item("昨日涨停", f"{previous.get('prevStreak', 1)} 板，昨日 {previous.get('prevTime') or '—'} 封板", "up"))
        groups.append({"title": "涨停数据（东方财富涨停池）", "items": limit_items})

    history = cached_daily(code)
    if history is None:
        try:
            history, _ = fetch_daily_rows(code, "year")
        except Exception as exc:
            print(f"Insight daily fetch failed for {code}: {exc}", flush=True)
            history = None
    features = daily_features(q, history, now) if history else None
    if features:
        f = features
        trend = ("均线多头" if f["ma5"] > f["ma10"] > f["ma20"] > f["ma60"] else
                 ("站上 20 日线" if price > f["ma20"] else "20 日线下方"))
        golden = "零轴上方金叉" if f["goldenCross"] and f["dif"][-1] > 0 else ("金叉" if f["goldenCross"] else ("多头" if f["dif"][-1] > f["dea"][-1] else "空头"))
        groups.append({"title": "日线结构（前复权）", "items": [
            item("趋势", trend, "up" if trend != "20 日线下方" else "down"),
            item("MA5 / MA10", f"{f['ma5']:.2f} / {f['ma10']:.2f}"),
            item("MA20 / MA60", f"{f['ma20']:.2f} / {f['ma60']:.2f}"),
            item("均线粘合度", f"{f['maSpread'] * 100:.1f}%", "up" if f["maSpread"] < 0.03 else "neutral", "5/10/20 日线最大间距，越小越蓄势"),
            item("乖离 20 日线", _fmt_pct(f["bias20"] * 100), "down" if f["bias20"] > 0.15 else _tone(f["bias20"])),
            item("近 5 / 20 / 60 日", f"{f['ret5'] * 100:+.1f}% / {f['ret20'] * 100:+.1f}% / {f['ret60'] * 100:+.1f}%", _tone(f["ret20"])),
            item("距 60 日高点", _fmt_pct((price / f["high60"] - 1) * 100), "up" if price > f["high60"] else "neutral", f"60 日高点 {f['high60']:.2f}，20 日高点 {f['high20']:.2f}"),
            item("成交额 / 5 日均额", f"{f['amountRatio']:.2f}×" if f["amountRatio"] else "—", _tone(f["amountRatio"], 1.5), "当日按 A 股 U 型成交分布折算全天"),
            item("5 日 / 20 日均额", f"{f['avg5'] / f['avg20']:.2f}" if f["avg20"] else "—", hint="小于 1 表示近期缩量"),
            item("近 20 日红肥绿瘦", f"{f['upAmount'] / f['downAmount']:.2f}" if f["downAmount"] else "—", _tone((f["upAmount"] / f["downAmount"]) if f["downAmount"] else None, 1.5), "上涨日成交额 / 下跌日成交额"),
            item("振幅收敛", f"{f['std10'] / f['std60']:.2f}" if f["std60"] else "—", "up" if f["std60"] and f["std10"] / f["std60"] < 0.65 else "neutral", "近 10 日波动 / 近 60 日波动"),
            item("MACD", golden, "up" if f["dif"][-1] > f["dea"][-1] else "down"),
            item("近 15 日涨停", f"{f['limitUps15']} 次", "up" if f["limitUps15"] else "neutral"),
        ]})

    payload = potential_payload(provider)
    matches = []
    for meta in STRATEGY_META:
        if meta["id"] == "all":
            continue
        entry = next((stock for stock in payload["lists"].get(meta["id"], []) if stock["code"] == code), None)
        if entry:
            matches.append({"strategy": meta["id"], "title": meta["title"], "score": entry["score"], "grade": entry["grade"],
                            "signals": entry.get("signals", []), "risks": entry.get("risks", []),
                            "highlights": entry.get("highlights", []), "pivot": entry.get("pivot"),
                            "stopLoss": entry.get("stopLoss"), "riskPercent": entry.get("riskPercent")})
    return {"code": code, "name": q.get("name", ""), "industry": industry or None, "concepts": concepts[:16],
            "groups": groups, "strategies": matches,
            "updatedAt": now.isoformat(timespec="seconds")}

def stock_news(code):
    with news_lock:
        cached = news_cache.get(code)
        if cached and time.time() - cached[0] < NEWS_TTL:
            return cached[1]
    import akshare as ak
    frame = ak.stock_news_em(symbol=code)
    items = []
    if frame is not None and not frame.empty:
        for _, row in frame.iterrows():
            title = str(row.get("新闻标题", "") or "").strip()
            if not title:
                continue
            content = " ".join(str(row.get("新闻内容", "") or "").split())
            items.append({"title": title, "content": content[:220], "time": str(row.get("发布时间", "") or "")[:16],
                          "source": str(row.get("文章来源", "") or ""), "url": str(row.get("新闻链接", "") or "")})
    items.sort(key=lambda entry: entry["time"], reverse=True)
    with news_lock:
        news_cache[code] = (time.time(), items[:20])
    print(f"Stock news ready for {code}: {len(items)} items", flush=True)
    return items[:20]

class Handler(BaseHTTPRequestHandler):
    def send_json(self, data, status=200, headers=None):
        body = json.dumps(data, ensure_ascii=False).encode()
        try:
            self.send_response(status); self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Content-Length", str(len(body)))
            for key, value in (headers or {}).items(): self.send_header(key, value)
            self.end_headers(); self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError) as exc:
            print(f"Client disconnected before response completed; status={status}, bytes={len(body)}, error={exc}", flush=True)
    def do_GET(self):
        parsed = urlparse(self.path); params = parse_qs(parsed.query)
        try:
            if parsed.path == "/health": return self.send_json({"status":"ok", "service":"astock-monitor-akshare", "api_version":API_VERSION, "akshare": AKSHARE_AVAILABLE, "providers": list(cache_by_provider.keys())})
            if parsed.path == "/index-quotes":
                global index_quote_cache
                cached_at, cached_rows = index_quote_cache
                if cached_rows and time.time() - cached_at < 5:
                    return self.send_json(cached_rows)
                import requests
                symbols = ",".join(INDEX_SYMBOLS)
                response = requests.get(
                    "https://qt.gtimg.cn/q=" + symbols,
                    headers={"Referer": "https://gu.qq.com/", "User-Agent": "Mozilla/5.0"}, timeout=8)
                response.raise_for_status()
                rows = []
                for line in response.text.splitlines():
                    if "=\"" not in line: continue
                    key, payload = line.split("=\"", 1)
                    symbol = key.removeprefix("v_")
                    fields = payload.rstrip("\";").split("~")
                    try:
                        price, previous_close = float(fields[3]), float(fields[4])
                        if symbol not in INDEX_SYMBOLS or price <= 0 or previous_close <= 0: continue
                        rows.append({"symbol": symbol, "name": INDEX_SYMBOLS[symbol], "price": price,
                                     "previousClose": previous_close, "changePercent": (price / previous_close - 1) * 100})
                    except (IndexError, TypeError, ValueError): continue
                if not rows: raise RuntimeError("Tencent did not return index quote rows")
                index_quote_cache = (time.time(), rows)
                print(f"Index quotes ready from Tencent: {len(rows)}/{len(INDEX_SYMBOLS)}", flush=True)
                return self.send_json(rows)
            if parsed.path == "/index-history":
                symbol = params.get("symbol", [""])[0]
                if symbol not in INDEX_SYMBOLS: return self.send_json({"error":"unsupported index symbol"}, 400)
                cached = index_history_cache.get(symbol)
                if cached and time.time() - cached[0] < 30:
                    return self.send_json(cached[1])
                import requests

                # Tencent's minute endpoint retains the latest trading session
                # after market close and on weekends. The previous AkShare call
                # queried today's date only, so it failed to provide history on
                # non-trading days and the Eastmoney upstream often disconnected.
                rows = []
                tencent_url = "https://ifzq.gtimg.cn/appstock/app/kline/mkline"
                try:
                    response = requests.get(
                        tencent_url,
                        params={"param": f"{symbol},m1,,320"},
                        headers={"Referer": "https://gu.qq.com/", "User-Agent": "Mozilla/5.0"},
                        timeout=10,
                    )
                    response.raise_for_status()
                    payload = response.json()
                    minute_rows = payload.get("data", {}).get(symbol, {}).get("m1", [])
                    parsed_rows = []
                    for item in minute_rows:
                        try:
                            stamp = datetime.strptime(str(item[0]), "%Y%m%d%H%M").replace(tzinfo=SHANGHAI_TZ)
                            price = float(item[2])
                            minute = stamp.hour * 60 + stamp.minute
                            if 570 <= minute <= 690 or 780 <= minute <= 900:
                                if price > 0:
                                    parsed_rows.append((stamp, price))
                        except (IndexError, TypeError, ValueError):
                            continue
                    if parsed_rows:
                        latest_day = max(stamp.date() for stamp, _ in parsed_rows)
                        rows = [
                            {"time": stamp.isoformat(timespec="seconds"), "price": price}
                            for stamp, price in parsed_rows if stamp.date() == latest_day
                        ]
                    print(f"Index minute history from Tencent: {symbol}, raw={len(minute_rows)}, latestSession={len(rows)}", flush=True)
                except Exception as exc:
                    print(f"Tencent index minute history failed for {symbol}: {exc}; trying AkShare", flush=True)

                # Fallback for environments where Tencent minute data is not reachable.
                if not rows:
                    import akshare as ak
                    date = datetime.now(SHANGHAI_TZ).strftime("%Y-%m-%d")
                    frame = ak.index_zh_a_hist_min_em(
                        symbol=symbol[-6:], period="1", start_date=f"{date} 09:30:00", end_date=f"{date} 15:00:00")
                    if frame is not None and not frame.empty:
                        for _, row in frame.iterrows():
                            stamp = str(row.get("时间", ""))[:19]
                            try:
                                price = float(row.get("收盘", 0))
                                parsed_stamp = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=SHANGHAI_TZ)
                                minute = parsed_stamp.hour * 60 + parsed_stamp.minute
                                if 570 <= minute <= 690 or 780 <= minute <= 900:
                                    if price > 0:
                                        rows.append({"time": parsed_stamp.isoformat(timespec="seconds"), "price": price})
                            except (TypeError, ValueError):
                                continue
                index_history_cache[symbol] = (time.time(), rows)
                print(f"Index minute history ready: {symbol} ({INDEX_SYMBOLS[symbol]}), {len(rows)} points", flush=True)
                return self.send_json(rows)
            if parsed.path == "/quotes":
                handler_started = time.monotonic()
                codes = set(params.get("codes", [""])[0].split(","))
                provider = params.get("provider", ["auto"])[0]
                market, lock_wait, upstream_fetch, cache_age = get_market(provider)
                data = [dict(item) for item in market if "*" in codes or item["code"] in codes]
                ensure_classifications()
                ensure_annual_profit_data()
                ensure_market_cap_data()
                ensure_zt()
                zt = zt_snapshot()
                zt_pool, zt_broken = zt["pool"], zt["broken"]
                with classification_lock:
                    known_industries = dict(industry_by_code)
                    known_concepts = {code: set(labels) for code, labels in concepts_by_code.items()}
                with annual_profit_lock:
                    annual_profits = annual_profit_by_code
                    annual_report_date = annual_profit_report_date
                    quarterly_profits = quarterly_profit_by_code
                    quarter_report_label = quarterly_profit_label
                    annual_updated_at = annual_profit_updated_at
                with market_cap_lock:
                    known_market_caps = market_cap_by_code
                    market_caps_updated_at = market_cap_updated_at
                # Board membership is pulled in the background, cached in memory, and
                # applied to quote rows on the next poll; it never delays prices.
                for item in data:
                    item["industry"] = known_industries.get(item["code"], item.get("industry", ""))
                    item["concept"] = ",".join(sorted(known_concepts.get(item["code"], set())))
                    item["annualNetProfit"] = annual_profits.get(item["code"])
                    item["annualReportYear"] = int(annual_report_date[:4]) if annual_report_date else None
                    item["quarterlyNetProfit"] = quarterly_profits.get(item["code"])
                    item["quarterlyReportLabel"] = quarter_report_label or None
                    market_cap = known_market_caps.get(item["code"], {})
                    if item.get("totalMarketCap") is None:
                        item["totalMarketCap"] = market_cap.get("total")
                    if item.get("floatMarketCap") is None:
                        item["floatMarketCap"] = market_cap.get("float")
                    limit_info = zt_pool.get(item["code"]) or zt_broken.get(item["code"])
                    if limit_info:
                        item["limitStreak"] = limit_info.get("streak") if item["code"] in zt_pool else None
                        item["firstLimitTime"] = limit_info.get("firstTime")
                        item["limitOpenCount"] = limit_info.get("openCount")
                        item["sealAmount"] = limit_info.get("sealAmount")
                        item["limitIndustry"] = limit_info.get("industry") or None
                industry_rows = sum(bool(item.get("industry")) for item in data)
                concept_rows = sum(bool(item.get("concept")) for item in data)
                print(f"Quote classification coverage: industries={industry_rows}/{len(data)}, concepts={concept_rows}/{len(data)}", flush=True)
                snapshot_time = cache_time_by_provider.get(provider, 0)
                revision = f"{provider}|{snapshot_time:.3f}|{classification_updated_at:.3f}|{annual_updated_at:.3f}|{market_caps_updated_at:.3f}|{zt['updatedAt']:.3f}|{','.join(sorted(codes))}"
                etag = '"' + hashlib.sha1(revision.encode()).hexdigest() + '"'
                if self.headers.get("If-None-Match") == etag:
                    print(f"GET /quotes status=304 provider={provider} rows={len(data)} lockWait={lock_wait:.3f}s handler={time.monotonic()-handler_started:.3f}s cacheAge={cache_age:.2f}s", flush=True)
                    self.send_response(304); self.send_header("ETag", etag)
                    self.send_header("X-Upstream-Fetch", f"{upstream_fetch:.3f}")
                    self.send_header("X-Snapshot-Cache", f"age={cache_age:.2f}s;lockWait={lock_wait:.3f}s")
                    self.send_header("Content-Length", "0"); self.end_headers()
                    return
                print(f"GET /quotes status=200 provider={provider} rows={len(data)} lockWait={lock_wait:.3f}s handler={time.monotonic()-handler_started:.3f}s upstreamFetch={upstream_fetch:.3f}s cacheAge={cache_age:.2f}s", flush=True)
                return self.send_json(data, headers={"ETag": etag, "X-Upstream-Fetch": f"{upstream_fetch:.3f}", "X-Snapshot-Cache": f"age={cache_age:.2f}s;lockWait={lock_wait:.3f}s"})
            if parsed.path == "/potential":
                provider = params.get("provider", ["auto"])[0]
                ensure_potential_scan(provider, force=params.get("force", ["0"])[0] == "1")
                return self.send_json(potential_payload(provider))
            if parsed.path in ("/stock-insight", "/news"):
                code = params.get("code", [""])[0]
                if len(code) != 6 or not code.isdigit(): return self.send_json({"error":"invalid code"}, 400)
                if parsed.path == "/news":
                    return self.send_json(stock_news(code))
                return self.send_json(stock_insight(code, params.get("provider", ["auto"])[0]))
            if parsed.path == "/pick-log":
                label = "".join(ch for ch in params.get("label", ["manual"])[0] if ch.isalnum() or ch in "-_")[:32] or "manual"
                return self.send_json(write_pick_log(label, params.get("provider", ["auto"])[0],
                                                     include_market=params.get("market", ["1"])[0] == "1"))
            if parsed.path == "/ohlc":
                codes = [c for c in params.get("codes", [""])[0].split(",") if len(c) == 6 and c.isdigit()][:200]
                snapshot = eastmoney_ohlc_snapshot(max_age=20)
                return self.send_json({code: snapshot[code] for code in codes if code in snapshot})
            if parsed.path == "/history":
                code = params.get("code", [""])[0]
                if len(code) != 6 or not code.isdigit(): return self.send_json({"error":"invalid code"}, 400)
                import akshare as ak
                now = datetime.now(SHANGHAI_TZ)
                date = now.strftime("%Y-%m-%d")
                frame = None
                try:
                    frame = ak.stock_zh_a_hist_min_em(
                        symbol=code, start_date=f"{date} 09:30:00", end_date=f"{date} 15:00:00",
                        period="1", adjust="")
                except Exception as exc:
                    print(f"Eastmoney minute history failed for {code}: {exc}; trying Sina", flush=True)
                if frame is None or frame.empty:
                    prefix = "sh" if code.startswith(("6", "9")) else "sz"
                    frame = ak.stock_zh_a_minute(symbol=prefix+code, period="1", adjust="")
                rows = []
                if frame is not None and not frame.empty:
                    # Sina fallback may include the previous session. Keep only
                    # today's regular trading session to avoid drawing a false
                    # overnight horizontal connector into today's open.
                    for _, row in frame.iterrows():
                        stamp = str(row.get("时间", row.get("day", row.get("日期", ""))))
                        raw_price = row.get("收盘", row.get("close", 0))
                        try:
                            price = float(raw_price)
                            if price <= 0: continue
                            parsed_stamp = datetime.strptime(stamp[:19], "%Y-%m-%d %H:%M:%S")
                            if parsed_stamp.strftime("%Y-%m-%d") != date:
                                continue
                            minute_of_day = parsed_stamp.hour * 60 + parsed_stamp.minute
                            if not (570 <= minute_of_day <= 900):
                                continue
                            # Upstream minute stamps are Beijing time; label them so the
                            # app draws correctly even when the Mac uses another time zone.
                            stamp = parsed_stamp.replace(tzinfo=SHANGHAI_TZ).isoformat(timespec="seconds")
                            rows.append({"time": stamp, "price": price})
                        except (TypeError, ValueError):
                            continue
                rows = rows[-240:]
                print(f"Minute history ready for {code}: {len(rows)} records", flush=True)
                return self.send_json(rows)
            if parsed.path == "/daily-history":
                code = params.get("code", [""])[0]
                range_name = params.get("range", ["year"])[0]
                if len(code) != 6 or not code.isdigit(): return self.send_json({"error":"invalid code"}, 400)
                if range_name not in ("5d", "1m", "3m", "year", "all"): return self.send_json({"error":"invalid range"}, 400)
                # Fetch and cache one year once; short K-line ranges are sliced
                # locally so switching 5d/1m/3m/year doesn't hit the provider again.
                cache_range = "all" if range_name == "all" else "year"
                def select_range(rows):
                    if range_name == "5d": return rows[-5:]
                    if range_name == "1m": return rows[-30:]
                    if range_name == "3m":
                        days = 92
                        cutoff = (datetime.now(SHANGHAI_TZ) - timedelta(days=days)).strftime("%Y-%m-%d")
                        return [row for row in rows if row["date"] >= cutoff]
                    return rows
                rows, source = fetch_daily_rows(code, cache_range)
                selected_rows = select_range(rows)
                print(f"Daily history ready for {code} range={range_name}: {len(selected_rows)} records (base={len(rows)}, source={source})", flush=True)
                return self.send_json(selected_rows)
            if parsed.path == "/five-day-trend":
                code = params.get("code", [""])[0]
                if len(code) != 6 or not code.isdigit(): return self.send_json({"error":"invalid code"}, 400)
                now = time.time()
                with daily_history_lock:
                    cached = five_day_trend_cache.get(code)
                    if cached and now - cached[0] < FIVE_DAY_TREND_CACHE_SECONDS:
                        print(f"Five-day minute trend cache hit for {code}: {len(cached[1])} points", flush=True)
                        return self.send_json(cached[1])
                import akshare as ak
                end_time = datetime.now(SHANGHAI_TZ).replace(tzinfo=None)
                start_time = end_time - timedelta(days=14)
                end = end_time.strftime("%Y-%m-%d %H:%M:%S")
                try:
                    frame = ak.stock_zh_a_hist_min_em(
                        symbol=code, start_date=start_time.strftime("%Y-%m-%d 09:30:00"), end_date=end,
                        period="1", adjust="")
                    source = "Eastmoney"
                except Exception as exc:
                    prefix = "sh" if code.startswith(("6", "9")) else "sz"
                    print(f"Eastmoney five-day minute history failed for {code}: {exc}; trying Sina", flush=True)
                    frame = ak.stock_zh_a_minute(symbol=prefix + code, period="1", adjust="")
                    source = "Sina"
                points = []
                if frame is not None and not frame.empty:
                    dates = []
                    parsed_rows = []
                    for _, row in frame.iterrows():
                        stamp = str(row.get("时间", row.get("day", row.get("日期", ""))))[:19]
                        try:
                            price = float(row.get("收盘", row.get("close", 0)))
                            parsed_stamp = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
                            if price <= 0: continue
                            date_key = parsed_stamp.strftime("%Y-%m-%d")
                            if date_key not in dates: dates.append(date_key)
                            parsed_rows.append((parsed_stamp, price, date_key))
                        except (TypeError, ValueError):
                            continue
                    keep_dates = set(dates[-5:])
                    points = [
                        {"time": stamp.replace(tzinfo=SHANGHAI_TZ).isoformat(timespec="seconds"), "price": price}
                        for stamp, price, date_key in parsed_rows if date_key in keep_dates
                    ]
                with daily_history_lock:
                    five_day_trend_cache[code] = (time.time(), points)
                print(f"Five-day minute trend ready for {code}: {len(points)} points, source={source}; cache={FIVE_DAY_TREND_CACHE_SECONDS}s", flush=True)
                return self.send_json(points)
            return self.send_json({"error":"not found"}, 404)
        except Exception as exc:
            print(f"request failed: {exc}", flush=True)
            return self.send_json({"error":str(exc)}, 502)
    def log_message(self, fmt, *args): print(f"{self.address_string()} {fmt % args}", flush=True)

# ---------------------------------------------------------------------------
# 推荐复盘日志：每个交易日 11:30 / 14:50 / 收盘后保存所有策略结果
# ---------------------------------------------------------------------------
PICK_LOG_DIRECTORY = CACHE_DIRECTORY / "pick-logs"
PICK_LOG_SLOTS = [("midday", 690, 780), ("1450", 890, 900), ("close", 901, 24 * 60)]
pick_log_lock = threading.Lock()
PICK_FIELDS = ("code", "name", "price", "changePercent", "industry", "score", "grade", "strategy", "strategies",
               "signals", "risks", "highlights", "tags", "pivot", "stopLoss", "riskPercent", "volumeRatio", "turnover",
               "amount", "floatMarketCap", "amountRatio", "ret20", "bias20", "pHi3", "pHi5", "takeProfit", "board",
               "gapRisk", "boardRank", "limitStreak", "firstLimitTime", "surgeTime", "buyable", "sector")

def write_pick_log(label, provider="auto", include_market=False):
    """Append one snapshot of every strategy list to pick-logs/YYYY-MM-DD.json."""
    now = datetime.now(SHANGHAI_TZ)
    day = now.strftime("%Y-%m-%d")
    payload = potential_payload(provider)
    snapshot = {
        "label": label, "time": now.isoformat(timespec="seconds"),
        "market": payload.get("market"), "emotion": payload.get("emotion"),
        "dailyScanUpdatedAt": payload.get("updatedAt"),
        "strategies": [{"id": s["id"], "title": s["title"], "count": s.get("count"), "note": s.get("note")}
                       for s in payload.get("strategies", [])],
        "lists": {sid: [{k: item.get(k) for k in PICK_FIELDS if item.get(k) is not None} for item in items]
                  for sid, items in payload.get("lists", {}).items()},
    }
    if include_market:
        try:
            ohlc = eastmoney_ohlc_snapshot(max_age=30)
        except Exception as exc:
            print(f"Pick log OHLC snapshot failed: {exc}", flush=True)
            ohlc = {}
        rows = []
        for q in _market_rows(provider):
            extra = ohlc.get(q["code"], {})
            rows.append({"code": q["code"], "name": q.get("name"), "price": q.get("price"),
                         "changePercent": q.get("changePercent"), "prevClose": extra.get("prevClose") or q.get("prevClose"),
                         "open": extra.get("open") or q.get("open"), "high": extra.get("high") or q.get("high"),
                         "low": extra.get("low") or q.get("low"), "amount": extra.get("amount") or q.get("amount"),
                         "volume": extra.get("volume") or q.get("volume"), "turnover": q.get("turnover"),
                         "volumeRatio": q.get("volumeRatio"), "floatMarketCap": q.get("floatMarketCap"),
                         "upperLimit": q.get("upperLimit"), "lowerLimit": q.get("lowerLimit")})
        snapshot["marketRows"] = rows
    PICK_LOG_DIRECTORY.mkdir(parents=True, exist_ok=True)
    path = PICK_LOG_DIRECTORY / f"{day}.json"
    with pick_log_lock:
        existing = _read_json_cache(path) or {}
        if not isinstance(existing, dict) or existing.get("day") != day:
            existing = {"day": day, "snapshots": {}}
        existing["snapshots"][label] = snapshot
        _write_json_cache(path, existing)
    counts = {sid: len(items) for sid, items in snapshot["lists"].items()}
    print(f"Pick log saved {path.name} label={label}: {counts}", flush=True)
    return {"path": str(path), "label": label, "counts": counts}

def _pick_log_has(day, label):
    payload = _read_json_cache(PICK_LOG_DIRECTORY / f"{day}.json")
    return isinstance(payload, dict) and payload.get("day") == day and label in (payload.get("snapshots") or {})

def pick_log_scheduler():
    while True:
        try:
            now = datetime.now(SHANGHAI_TZ)
            minute = now.hour * 60 + now.minute
            day = now.strftime("%Y-%m-%d")
            if now.weekday() < 5:
                for label, start, end in PICK_LOG_SLOTS:
                    if start <= minute < end and not _pick_log_has(day, label):
                        write_pick_log(label, include_market=label in ("1450", "close"))
        except Exception as exc:
            print(f"Pick log scheduler failed: {exc}", flush=True)
        time.sleep(30)

if __name__ == "__main__":
    threading.Thread(target=pick_log_scheduler, name="pick-log", daemon=True).start()
    print(f"AkShare bridge listening on http://{HOST}:{PORT}; quote cache={CACHE_SECONDS}s; derived-data disk caches=24h", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
