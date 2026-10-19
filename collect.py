#!/usr/bin/env python3
"""Claude Code 사용량 집계기.

~/.claude/projects/**/*.jsonl 을 스캔해 토큰/비용을 집계하고 JSON으로 출력한다.
파일 단위 캐시(mtime+size)를 써서 두 번째 실행부터는 변경된 파일만 다시 읽는다.
"""
import json, os, sys, time, glob
import limits as limits_mod
import codex as codex_mod
from datetime import datetime, timezone, timedelta

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
# 캐시는 macOS 관례대로 ~/Library/Caches 아래에 둔다. 소스 트리와 분리해야
# 저장소를 어디로 옮기든 동작하고, 캐시가 소스처럼 보이지 않는다.
CACHE_DIR = os.path.join(HOME, "Library", "Caches", "CCUsage")
CACHE = os.path.join(CACHE_DIR, "usage-cache.json")
RETAIN_DAYS = 45          # 캐시에 남겨둘 기간
BLOCK_HOURS = 5           # Claude 사용 한도 블록 길이

# $/1M tokens: (input, output). cache read = input*0.1, cache write 5m = input*1.25, 1h = input*2
PRICES = {
    "claude-fable-5-1":  (10.0, 50.0),
    "claude-fable-5":    (10.0, 50.0),
    "claude-mythos-5-1": (10.0, 50.0),
    "claude-opus-5":     (5.0, 25.0),
    "claude-opus-4-8":   (5.0, 25.0),
    "claude-opus-4-7":   (5.0, 25.0),
    "claude-opus-4-6":   (5.0, 25.0),
    "claude-sonnet-5":   (2.0, 10.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5":  (1.0, 5.0),
}
DEFAULT_PRICE = (5.0, 25.0)


def price_for(model):
    if model in PRICES:
        return PRICES[model]
    for k, v in PRICES.items():          # claude-opus-4-5-20251101 같은 날짜 접미사 대응
        if model.startswith(k):
            return v
    m = model or ""
    if "haiku" in m:  return PRICES["claude-haiku-4-5"]
    if "sonnet" in m: return PRICES["claude-sonnet-5"]
    if "fable" in m or "mythos" in m: return PRICES["claude-fable-5-1"]
    return DEFAULT_PRICE


def cost_of(rec):
    """rec = [ts, model, inp, out, cw5, cw1h, cr] -> USD"""
    _, model, inp, out, cw5, cw1h, cr = rec
    pin, pout = price_for(model)
    return (inp * pin + out * pout + cw5 * pin * 1.25 + cw1h * pin * 2.0 + cr * pin * 0.1) / 1_000_000


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def scan_file(path, cutoff):
    """파일 하나에서 usage 레코드를 뽑는다. -> [[ts, model, in, out, cw5, cw1h, cr, reqid], ...]"""
    out = []
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                u = msg.get("usage")
                if not isinstance(u, dict):
                    continue
                ts = parse_ts(d.get("timestamp", ""))
                if ts < cutoff:
                    continue
                cc = u.get("cache_creation") or {}
                cw5 = cc.get("ephemeral_5m_input_tokens")
                cw1 = cc.get("ephemeral_1h_input_tokens")
                if cw5 is None and cw1 is None:
                    cw5, cw1 = u.get("cache_creation_input_tokens", 0) or 0, 0
                out.append([
                    ts,
                    msg.get("model") or "unknown",
                    u.get("input_tokens", 0) or 0,
                    u.get("output_tokens", 0) or 0,
                    cw5 or 0,
                    cw1 or 0,
                    u.get("cache_read_input_tokens", 0) or 0,
                    d.get("requestId") or d.get("uuid") or "",
                ])
    except OSError:
        pass
    return out


def load_cache():
    try:
        with open(CACHE) as f:
            c = json.load(f)
        if c.get("v") == 2:
            return c
    except Exception:
        pass
    return {"v": 2, "files": {}}


def collect():
    now = time.time()
    cutoff = now - RETAIN_DAYS * 86400
    cache = load_cache()
    files = cache["files"]
    seen = set()

    for path in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
        try:
            st = os.stat(path)
        except OSError:
            continue
        seen.add(path)
        ent = files.get(path)
        if ent and ent["mtime"] == int(st.st_mtime) and ent["size"] == st.st_size:
            continue
        if st.st_mtime < cutoff:                      # 오래된 파일은 빈 항목으로 기록만
            files[path] = {"mtime": int(st.st_mtime), "size": st.st_size, "r": []}
            continue
        files[path] = {"mtime": int(st.st_mtime), "size": st.st_size, "r": scan_file(path, cutoff)}

    for p in list(files):                             # 사라진 파일 정리
        if p not in seen:
            del files[p]

    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE)
    except OSError:
        pass

    recs, dedup = [], set()
    for ent in files.values():
        for r in ent["r"]:
            rid = r[7]
            if rid:
                if rid in dedup:
                    continue
                dedup.add(rid)
            if r[0] >= cutoff:
                recs.append(r[:7])
    recs.sort(key=lambda r: r[0])
    return recs, now


def agg(recs):
    tot = {"cost": 0.0, "in": 0, "out": 0, "cache_w": 0, "cache_r": 0, "n": 0, "models": {}}
    for r in recs:
        c = cost_of(r)
        tot["cost"] += c
        tot["in"] += r[2]; tot["out"] += r[3]
        tot["cache_w"] += r[4] + r[5]; tot["cache_r"] += r[6]
        tot["n"] += 1
        m = tot["models"].setdefault(r[1], {"cost": 0.0, "tok": 0})
        m["cost"] += c
        m["tok"] += r[2] + r[3] + r[4] + r[5] + r[6]
    tot["tok"] = tot["in"] + tot["out"] + tot["cache_w"] + tot["cache_r"]
    tot["models"] = sorted(
        [{"model": k, **v} for k, v in tot["models"].items()],
        key=lambda x: -x["cost"])[:4]
    return tot


def current_block(recs, now):
    """ccusage 식 5시간 블록: 첫 요청의 정시에 앵커, 5시간 초과 공백이면 새 블록."""
    if not recs:
        return None
    start = None
    last = None
    for r in recs:
        ts = r[0]
        if start is None or ts - start >= BLOCK_HOURS * 3600 or (last and ts - last >= BLOCK_HOURS * 3600):
            start = (int(ts) // 3600) * 3600
        last = ts
    end = start + BLOCK_HOURS * 3600
    if now >= end:
        return {"active": False, "start": start, "end": end, **agg([r for r in recs if start <= r[0] < end])}
    return {"active": True, "start": start, "end": end, **agg([r for r in recs if r[0] >= start])}


def providers():
    cl = limits_mod.fetch()
    cx = codex_mod.fetch()
    out = []
    if cl.get("limits"):
        out.append({"id": "claude", "name": "Claude Code", "plan": None,
                    "stale": bool(cl.get("stale")), "fetched": cl.get("fetched", 0),
                    "reason": cl.get("reason"), "limits": cl["limits"]})
    if cx.get("limits"):
        out.append({"id": "codex", "name": "Codex", "plan": cx.get("plan"),
                    "stale": bool(cx.get("stale")), "fetched": cx.get("fetched", 0),
                    "reason": "기록 오래됨" if cx.get("stale") else None,
                    "limits": cx["limits"]})
    return out


def main():
    recs, now = collect()
    tz = datetime.now().astimezone().tzinfo
    day_start = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    week_start = day_start - 6 * 86400
    month_start = day_start - 29 * 86400

    days = []
    for i in range(7):
        s = day_start - i * 86400
        e = s + 86400
        d = agg([r for r in recs if s <= r[0] < e])
        days.append({"date": datetime.fromtimestamp(s, tz).strftime("%m/%d"), "cost": d["cost"], "tok": d["tok"]})
    days.reverse()

    out = {
        "generated": now,
        "block": current_block(recs, now),
        "today": agg([r for r in recs if r[0] >= day_start]),
        "week": agg([r for r in recs if r[0] >= week_start]),
        "month": agg([r for r in recs if r[0] >= month_start]),
        "days": days,
        "last_activity": recs[-1][0] if recs else 0,
        # 실제 플랜 한도. 두 제품을 같은 구조로 합쳐서 위젯이 동일하게 그린다.
        #  - Claude: JSONL 에 없어 `claude -p /usage` 파싱 (5분 캐시)
        #  - Codex : ~/.codex/sessions 의 rate_limits 를 직접 읽음
        "providers": providers(),
    }
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
