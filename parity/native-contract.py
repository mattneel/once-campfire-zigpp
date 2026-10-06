#!/usr/bin/env python3
"""Finite native/Rust HTTP conformance subset; never a claim about the whole suite.

Python 3.10+ on Unix, standard library only. Servers must already run over separate,
fresh copies of --seed, with the seed's Rails secret. All writes use HTTP. SQLite
connections are read-only. No benchmark, source inspection, or fixture HTTP replay.
Run with --help for the exact interface. JSON on stdout; exit 1 on any failed check.
"""

import argparse
import datetime as dt
import hashlib
import http.cookies
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import signal
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
TURBO = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
ANCHORS = {
    "prerequisites": ["parity/seeds/default.rb:151-165", "vectors/campfire_sessions.json"],
    "authentication": ["crates/campfire/src/app/tests.rs:a_rails_issued_session_cookie_authenticates",
                       "crates/campfire/src/controllers/sessions.rs:create/destroy"],
    "room_access": ["crates/campfire/src/controllers/rooms/tests.rs:inaccessible_rooms_redirect_home_with_an_alert",
                    "crates/campfire/src/controllers/messages/tests.rs:index_pages_with_conditional_gets"],
    "room_dom": ["crates/campfire/src/controllers/rooms/tests.rs:show_renders_the_room_and_remembers_it",
                 "crates/campfire/src/controllers/presenters/accounts/tests.rs:profile_sidebar_and_user_pages"],
    "pagination": ["crates/campfire/src/controllers/rooms/tests.rs:show_at_a_message_pages_around_it",
                   "crates/campfire/src/controllers/messages/tests.rs:index_pages_with_conditional_gets",
                   "crates/db/src/tests/message_test.rs:pagination", "parity/seeds/default.rb:151-165"],
    "sidebar": ["crates/campfire/src/controllers/presenters/accounts/tests.rs:profile_sidebar_and_user_pages",
                "crates/campfire/src/controllers/presenters/accounts.rs:sidebar"],
    "search": ["crates/db/src/tests/message_test.rs:search_reachable_only_finds_messages_in_the_users_rooms",
               "crates/campfire/src/controllers/searches.rs:the_index_shows_results_recent_searches_and_the_way_back"],
    "search_history": ["crates/campfire/src/controllers/searches.rs:searching_records_and_clears_recent_searches"],
    "message_write": ["crates/campfire/src/controllers/messages/tests.rs:create_appends_the_message_as_a_turbo_stream",
                      "crates/campfire/src/controllers/messages/tests.rs:a_text_message_is_answered_and_broadcast_as_it_was_stored",
                      "crates/db/src/tests/message_test.rs:rich_text_body_is_converted_to_plain_text_for_indexing",
                      "crates/db/src/tests/callbacks_test.rs:creating_a_message_touches_the_room_marks_disconnected_members_unread_and_indexes_after_commit",
                      "crates/db/src/models/message.rs:create", "crates/db/src/models/room.rs:unread_memberships"],
    "unsafe_richtext": ["crates/richtext/src/sanitizer.rs:scrubs_like_rails",
                        "crates/richtext/tests/reference_tests.rs:message_presentation_strips_event_handler_attributes_from_allowed_tags",
                        "crates/richtext/tests/hardening.rs:a_url_after_a_greater_than_sign_in_an_attribute_cannot_break_out_of_it",
                        "crates/richtext/src/autolink.rs:auto_link",
                        "crates/richtext/src/filters.rs:sanitize_tags/sanitize_attributes"],
}


class Failure(Exception):
    def __init__(self, assertion, expected=None, actual=None):
        super().__init__(assertion)
        self.evidence = {"assertion": assertion, "expected": expected, "actual": actual}


def check(condition, assertion, expected=None, actual=None):
    if not condition:
        raise Failure(assertion, expected, actual)


def equal(actual, expected, assertion):
    check(actual == expected, assertion, expected, actual)


class Node:
    def __init__(self, tag, attrs=()):
        self.tag = tag
        self.attrs = dict(attrs)
        self.children = []

    def walk(self):
        yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.walk()

    def text(self):
        return "".join(c.text() if isinstance(c, Node) else c for c in self.children)

    def find(self, predicate):
        return [n for n in self.walk() if predicate(n)]


class DOM(HTMLParser):
    VOID = set("area base br col embed hr img input link meta param source track wbr".split())

    def __init__(self, body):
        super().__init__(convert_charrefs=True)
        self.root = Node("#document")
        self.stack = [self.root]
        self.feed(body)
        self.close()

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, text):
        self.stack[-1].children.append(text)

    def handle_decl(self, decl):
        self.stack[-1].children.append(Node("!" + decl.lower()))


def one(root, predicate, description):
    nodes = root.find(predicate)
    equal(len(nodes), 1, description + " exists exactly once")
    return nodes[0]


def by_id(root, value):
    return one(root, lambda n: n.attrs.get("id") == value, value)


def messages(root):
    return root.find(lambda n: "data-message-id" in n.attrs and "reply" in n.attrs.get("data-controller", "").split())


def message_ids(root):
    return [int(n.attrs["data-message-id"]) for n in messages(root)]


def presentation(node):
    return one(node, lambda n: n.attrs.get("data-reply-target") == "body", "message presentation")


def canonical(node, base, dynamic_message=False, content=False, literal=False):
    """DOM equivalence: unordered attributes, serialization-only indentation.

    Only volatile values are host, CSRF masks, CSP nonce, and (for newly posted
    messages only) message timestamps. Seed timestamps, IDs, signatures, classes,
    grouping, links, text, and all other attributes are retained. Significant
    rich-text whitespace and pre/code/script/style text are kept verbatim.
    """
    attrs = dict(node.attrs)
    content = content or attrs.get("data-reply-target") == "body"
    literal = literal or node.tag in {"pre", "code", "script", "style"}
    for key, value in attrs.items():
        if value is not None:
            value = value.replace(base, "{SERVER}")
        if key == "nonce":
            value = "{NONCE}"
        if node.tag == "meta" and attrs.get("name") == "csrf-token" and key == "content":
            value = "{CSRF}"
        if node.tag == "input" and attrs.get("name") == "authenticity_token" and key == "value":
            value = "{CSRF}"
        if dynamic_message and key in {"data-message-timestamp", "data-message-updated-at", "data-sort-value", "datetime"}:
            value = "{POST_TIME}"
        attrs[key] = value
    if node.tag == "script" and attrs.get("type") == "text/template":
        embedded = DOM(node.text()).root
        return [node.tag, sorted(attrs.items()), [canonical(embedded, base, dynamic_message)]]
    children = []
    for child in node.children:
        if isinstance(child, Node):
            children.append(canonical(child, base, dynamic_message, content, literal))
        elif literal:
            children.append(child.replace("\r\n", "\n").replace(base, "{SERVER}"))
        elif child.strip():
            children.append(child if content else re.sub(r"\s+", " ", child).strip())
    return [node.tag, sorted(attrs.items()), children]


def difference(actual, expected, path="DOM"):
    if type(actual) is not type(expected):
        return {"path": path, "native": actual, "oracle": expected}
    if isinstance(actual, (list, tuple)):
        if len(actual) != len(expected):
            return {"path": path + ".length", "native": len(actual), "oracle": len(expected)}
        for i, (a, e) in enumerate(zip(actual, expected)):
            if a != e:
                return difference(a, e, f"{path}[{i}]")
    elif actual != expected:
        return {"path": path, "native": actual, "oracle": expected}
    return None


def request_expired(signum, frame):
    raise TimeoutError("absolute HTTP request deadline exceeded")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Reply:
    def __init__(self, response):
        self.status = response.code
        self.headers = response.headers
        limit = 8 * 1024 * 1024
        body = response.read(limit + 1)
        check(len(body) <= limit, "HTTP response exceeds finite gate body limit", limit, len(body))
        self.body = body.decode("utf-8", errors="strict")
        self.dom = DOM(self.body).root

    def header(self, name):
        return self.headers.get(name)

    def evidence(self):
        return {"status": self.status, "content_type": self.header("content-type"),
                "location": self.header("location"), "bytes": len(self.body.encode()),
                "x_version": self.header("x-version"), "x_rev": self.header("x-rev"),
                "sha256": hashlib.sha256(self.body.encode()).hexdigest()}


class Client:
    def __init__(self, base, timeout, cookie=None):
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.cookies = {}
        if cookie:
            self.absorb(cookie)
        self.opener = urllib.request.build_opener(NoRedirect())

    def absorb(self, raw):
        cookies = http.cookies.SimpleCookie()
        cookies.load(raw)
        for name, morsel in cookies.items():
            if not morsel.value or morsel["max-age"] == "0":
                self.cookies.pop(name, None)
            else:
                self.cookies[name] = morsel.value

    def request(self, path, method="GET", form=None, headers=None):
        data = None
        hdr = {"Accept": "text/html,application/xhtml+xml", "User-Agent": UA,
               "Accept-Encoding": "identity"}
        if self.cookies:
            hdr["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        if method != "GET":
            hdr.update({"Origin": self.base, "Sec-Fetch-Site": "same-origin"})
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            hdr["Content-Type"] = "application/x-www-form-urlencoded"
        if headers:
            hdr.update(headers)
        req = urllib.request.Request(self.base + path, data=data, headers=hdr, method=method)
        previous_handler = signal.signal(signal.SIGALRM, request_expired)
        signal.setitimer(signal.ITIMER_REAL, self.timeout)
        try:
            try:
                response = self.opener.open(req, timeout=self.timeout)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                reply = Reply(response)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
        for value in reply.headers.get_all("Set-Cookie", []):
            self.absorb(value)
        return reply


def sql_open(path):
    path = Path(path).resolve(strict=True)
    conn = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    return conn


def rows(conn, query, args=()):
    return [dict(r) for r in conn.execute(query, args)]


def timestamp(value):
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        result = result.replace(tzinfo=dt.timezone.utc)
    return result.astimezone(dt.timezone.utc)


def epoch_ms(value):
    delta = timestamp(value) - dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    # Match Rails' Time#to_f then truncation, including its real floating-point edges.
    seconds = float(f"{delta.days * 86400 + delta.seconds}.{delta.microseconds:06d}")
    return int(seconds * 1000.0)


class Gate:
    def __init__(self, args):
        self.args = args
        self.seed = Path(args.seed).resolve(strict=True)
        self.labels = json.loads((self.seed / "labels.json").read_text())
        self.vectors = json.loads((ROOT / "vectors/campfire_sessions.json").read_text())
        self.canonical_db = sql_open(self.seed / "db/production.sqlite3")
        self.native_db = sql_open(args.db)
        self.oracle_db = sql_open(args.oracle_db) if args.oracle_db else None
        self.run_id = "nativegate" + uuid.uuid4().hex
        self.clients = {}
        self.results = []
        self.observations = []

    def label(self, key):
        check(key in self.labels, "required canonical label", key, list(self.labels))
        return self.labels[key]

    def pair(self, user="david"):
        if user not in self.clients:
            pair = [Client(base, self.args.timeout) for base in (self.args.base, self.args.oracle)]
            if user == "david":
                vector = next(v for v in self.vectors["sessions"] if v["user_id"] == self.label("users.david"))
                for client in pair:
                    client.absorb(vector["cookie_header"])
            else:
                for client in pair:
                    reply = client.request("/session", "POST", {
                        "email_address": self.label("emails." + user), "password": self.label("passwords.all")})
                    equal(reply.status, 302, user + " login")
                    check("session_token" in client.cookies, user + " session cookie issued")
            self.clients[user] = pair
        return self.clients[user]

    def both(self, path, method="GET", form=None, headers=None, user="david", pair=None):
        pair = pair or self.pair(user)
        replies = [client.request(path, method, form, headers) for client in pair]
        self.observations.append({"method": method, "path": path, "user": user,
                                  "native": replies[0].evidence(), "oracle": replies[1].evidence()})
        return replies

    def compare(self, replies, status=200, dom=True):
        native, oracle = replies
        equal(oracle.status, status, "Rust oracle status")
        equal(native.status, oracle.status, "native status equals live Rust")
        for header in ("content-type", "cache-control", "x-frame-options", "referrer-policy", "x-content-type-options"):
            equal(native.header(header), oracle.header(header), header + " semantics")
        equal((native.header("link") or "").replace(self.args.base, "{SERVER}"),
              (oracle.header("link") or "").replace(self.args.oracle, "{SERVER}"), "asset preload Link semantics")
        equal(sorted(s.strip().lower() for s in (native.header("vary") or "").split(",") if s.strip()),
              sorted(s.strip().lower() for s in (oracle.header("vary") or "").split(",") if s.strip()), "Vary semantics")
        # Build provenance may differ by implementation; retain actual values in evidence.
        for header in ("x-version", "x-rev"):
            equal(bool(native.header(header)), bool(oracle.header(header)), header + " provenance header presence")
        for reply, base in zip(replies, (self.args.base, self.args.oracle)):
            location = reply.header("location")
            if location:
                check(location.startswith(base) or location.startswith("/"), "redirect remains on server", base, location)
        equal((native.header("location") or "").replace(self.args.base, "{SERVER}"),
              (oracle.header("location") or "").replace(self.args.oracle, "{SERVER}"), "redirect destination")
        if dom:
            a = canonical(native.dom, self.args.base)
            e = canonical(oracle.dom, self.args.oracle)
            diff = difference(a, e)
            check(diff is None, "live response DOM parity", None, diff)

    def compare_message(self, native, oracle, dynamic=False):
        diff = difference(canonical(native, self.args.base, dynamic), canonical(oracle, self.args.oracle, dynamic))
        check(diff is None, "live message DOM parity (content/order/grouping retained)", None, diff)

    def run(self, name, callback):
        start = time.monotonic()
        observations = len(self.observations)
        result = {"scenario": name, "source_anchors": ANCHORS[name]}
        try:
            evidence = callback()
            result.update(status="pass", evidence=evidence)
        except Failure as error:
            result.update(status="fail", evidence=error.evidence)
        except Exception as error:
            result.update(status="fail", evidence={"error_type": type(error).__name__, "error": str(error)})
        result["elapsed_seconds"] = round(time.monotonic() - start, 6)
        result["requests"] = self.observations[observations:]
        self.results.append(result)
        return result["status"] == "pass"

    def prerequisites(self):
        native_path = Path(self.args.db).resolve(strict=True)
        seed_path = (self.seed / "db/production.sqlite3").resolve(strict=True)
        check(not native_path.samefile(seed_path), "native must use dedicated seed copy, not canonical DB")
        check(self.args.base != self.args.oracle, "native and oracle URLs must differ")
        if self.oracle_db:
            oracle_path = Path(self.args.oracle_db).resolve(strict=True)
            check(not oracle_path.samefile(native_path) and not oracle_path.samefile(seed_path),
                  "oracle, native and canonical DBs must be isolated")
        # Fresh copies are required. HTTP writes from a preceding gate invalidate this precondition.
        for table in ("messages", "action_text_rich_texts", "rooms", "memberships", "users", "searches"):
            expected = rows(self.canonical_db, f'SELECT * FROM "{table}" ORDER BY id')
            equal(rows(self.native_db, f'SELECT * FROM "{table}" ORDER BY id'), expected,
                  "native starts with exact canonical " + table)
            if self.oracle_db:
                equal(rows(self.oracle_db, f'SELECT * FROM "{table}" ORDER BY id'), expected,
                      "oracle starts with exact canonical " + table)
        equal(rows(self.native_db, "SELECT rowid,body FROM message_search_index ORDER BY rowid"),
              rows(self.canonical_db, "SELECT rowid,body FROM message_search_index ORDER BY rowid"),
              "native seeded FTS content")
        if self.oracle_db:
            equal(rows(self.oracle_db, "SELECT rowid,body FROM message_search_index ORDER BY rowid"),
                  rows(self.canonical_db, "SELECT rowid,body FROM message_search_index ORDER BY rowid"),
                  "oracle seeded FTS content")
        vector = next(v for v in self.vectors["sessions"] if v["user_id"] == self.label("users.david"))
        session = rows(self.native_db, "SELECT token,user_id FROM sessions WHERE id=?", (vector["session_id"],))
        equal(session, [{"token": vector["token"], "user_id": vector["user_id"]}], "Rails cookie targets actual seeded session")
        loner = self.label("users.loner")
        equal(rows(self.native_db, "SELECT id FROM searches WHERE user_id=?", (loner,)), [], "isolated history user starts empty")
        self.watercooler = self.label("rooms.watercooler")
        self.all_watercooler = rows(self.canonical_db, "SELECT id,created_at FROM messages WHERE room_id=? ORDER BY created_at,id", (self.watercooler,))
        check(len(self.all_watercooler) >= 121, "canonical busy room has real 81-window boundaries", ">=121", len(self.all_watercooler))
        self.anchor = self.label("messages.busy_061")
        equal(self.all_watercooler[60]["id"], self.anchor, "canonical middle anchor")
        return {"seed": str(self.seed), "native_db": str(native_path), "oracle_db": self.args.oracle_db,
                "watercooler_rows": len(self.all_watercooler), "canonical_label_count": len(self.labels),
                "oracle_image_required": "ccece30e8e160d8c3e05bf395ee55ee35962093b"}

    def authentication(self):
        room = f"/rooms/{self.watercooler}"
        for cookie in (None, self.vectors["forged"]["cookie_header"], "session_token=tampered--0000"):
            pair = [Client(base, self.args.timeout, cookie) for base in (self.args.base, self.args.oracle)]
            replies = self.both(room, pair=pair)
            self.compare(replies, 302, dom=False)
            for reply in replies:
                check((reply.header("location") or "").endswith("/session/new"), "anonymous/forged cookie redirects to login")
        pair = [Client(base, self.args.timeout) for base in (self.args.base, self.args.oracle)]
        self.compare(self.both("/session/new", pair=pair))
        rejected = self.both("/session", "POST", {"email_address": self.label("emails.david"),
                                                     "password": "not-the-canonical-password"}, pair=pair)
        self.compare(rejected, 401)
        for client, reply in zip(pair, rejected):
            check("Too many requests or unauthorized." in reply.dom.text(), "password rejection alert")
            check("session_token" not in client.cookies, "invalid password creates no authentication cookie")
        logged_in = self.both("/session", "POST", {"email_address": self.label("emails.david"),
                                                      "password": self.label("passwords.all")}, pair=pair)
        self.compare(logged_in, 302, dom=False)
        for client, reply in zip(pair, logged_in):
            check("session_token" in client.cookies, "real password creates signed session")
            raw = next((v for v in reply.headers.get_all("set-cookie", []) if v.startswith("session_token=")), "")
            check("httponly" in raw.lower() and "samesite=lax" in raw.lower(), "session cookie HTTPOnly/SameSite=Lax", "secure cookie attributes", raw)
        # The original Rails-issued cookie must authenticate independently of password login.
        rails = self.both(room)
        self.compare(rails)
        for reply in rails:
            equal(message_ids(reply.dom), [m["id"] for m in self.all_watercooler[-40:]], "Rails-issued cookie sees actual room data")
            raw = next((v for v in reply.headers.get_all("set-cookie", []) if v.startswith("session_token=")), "")
            check("httponly" in raw.lower() and "samesite=lax" in raw.lower(), "stale Rails session is refreshed with signed cookie", "refresh cookie", raw)
        again = self.both(room)
        self.compare(again)
        for reply in again:
            check(not any(v.startswith("session_token=") for v in reply.headers.get_all("set-cookie", [])), "fresh session is not refreshed again within hour")
        logout = self.both("/session", "DELETE", pair=pair)
        self.compare(logout, 302, dom=False)
        self.compare(self.both(room, pair=pair), 302, dom=False)
        return {"password_login": True, "password_rejection": True, "rails_cookie": True,
                "forged_and_tampered_denied": True, "refresh_once": True, "logout": True}

    def room_access(self):
        denied = [("david", self.label("rooms.bender_and_kevin")),
                  ("kevin", self.label("rooms.david_and_jason"))]
        for user, room_id in denied:
            self.compare(self.both(f"/rooms/{room_id}", user=user), 302, dom=False)
            self.compare(self.both(f"/rooms/{room_id}/messages", user=user), 404, dom=False)
        # Kevin can access his own room: denial is membership enforcement, not universal failure.
        own = self.label("rooms.bender_and_kevin")
        self.compare(self.both(f"/rooms/{own}", user="kevin"))
        return {"denied_rooms": denied, "authorized_control": own}

    def room_dom(self):
        tested = []
        for label in ("watercooler", "designers", "david_and_jason", "quiet"):
            room = self.label("rooms." + label)
            path = f"/rooms/{room}"
            previous_rooms = [client.cookies.get("last_room") for client in self.pair()]
            full = self.both(path)
            self.compare(full)
            frame = self.both(path, headers={"Turbo-Frame": "main-content"})
            self.compare(frame)
            for index, reply in enumerate(full):
                check("<!doctype html>" in reply.body.lower(), "room full document contains doctype")
                equal(one(reply.dom, lambda n: n.tag == "meta" and n.attrs.get("name") == "current-room-id", "current room meta").attrs.get("content"), str(room), "current room metadata")
                cookies = reply.headers.get_all("set-cookie", [])
                issued = any(v.startswith(f"last_room={room}") for v in cookies)
                equal(issued, previous_rooms[index] != str(room), "last_room cookie is issued when room changes")
                equal(self.pair()[index].cookies.get("last_room"), str(room), "visited room is retained in client cookie")
            for reply in frame:
                check("<!doctype" not in reply.body.lower(), "Turbo-Frame layout omits full-document doctype")
                one(reply.dom, lambda n: n.tag == "html", "Rails frame HTML wrapper")
                by_id(reply.dom, "message-area")
                check(not reply.dom.find(lambda n: n.attrs.get("id") in {"nav", "sidebar", "footer"}), "room frame omits application navigation/sidebar/footer")
            tested.append({"room": room, "message_ids": message_ids(full[0].dom)})
        return {"full_and_frame_dom": tested, "includes_seeded_richtext_boosts_attachments_and_grouping": True}

    def pagination(self):
        ids = [m["id"] for m in self.all_watercooler]
        prefix = f"/rooms/{self.watercooler}/messages"
        scenarios = [("before", f"{prefix}?before={self.anchor}", ids[20:60]),
                     ("after", f"{prefix}?after={self.anchor}", ids[61:101]),
                     ("last", prefix, ids[-40:]),
                     ("before_precedence", f"{prefix}?before={self.anchor}&after={ids[-1]}", ids[20:60])]
        counts = {}
        for name, path, expected in scenarios:
            replies = self.both(path)
            self.compare(replies)
            for reply in replies:
                equal(message_ids(reply.dom), expected, name + " exact ordered real IDs")
                check(not reply.dom.find(lambda n: n.tag == "html"), "message pagination layout false")
            counts[name] = len(expected)
        for anchor, expected in ((self.anchor, ids[20:101]), (ids[0], ids[:41]), (ids[-1], ids[-41:])):
            replies = self.both(f"/rooms/{self.watercooler}/@{anchor}")
            self.compare(replies)
            for reply in replies:
                equal(message_ids(reply.dom), expected, "around anchor exact ordered window")
            counts["around_" + str(anchor)] = len(expected)
        for path in (f"{prefix}?before={ids[0]}", f"{prefix}?after={ids[-1]}"):
            replies = self.both(path)
            self.compare(replies, 204, dom=False)
            for reply in replies:
                equal(reply.body, "", "empty page is bodyless 204")
        foreign = self.label("messages.direct_first")
        for path in (f"{prefix}?before={foreign}", f"{prefix}?after={foreign}", f"{prefix}?before=0"):
            replies = self.both(path)
            self.compare(replies, 404, dom=False)
            for reply in replies:
                equal(message_ids(reply.dom), [], "wrong-room anchor never leaks messages")
        # Room deep links intentionally differ: a foreign or missing anchor falls back to last page.
        for anchor in (foreign, 0):
            replies = self.both(f"/rooms/{self.watercooler}/@{anchor}")
            self.compare(replies)
            for reply in replies:
                equal(message_ids(reply.dom), ids[-40:], "wrong-room deep link falls back to last page")
        path = f"{prefix}?before={self.anchor}"
        fresh = self.both(path)
        self.compare(fresh)
        for client, reply in zip(self.pair(), fresh):
            etag = reply.header("etag")
            check(etag and re.fullmatch(r'W/"[^"\r\n]+"', etag), "pagination ETag is weak quoted validator", "W/quoted", etag)
            check(reply.header("last-modified"), "pagination Last-Modified exists")
            cached = client.request(path, headers={"If-None-Match": etag})
            equal(cached.status, 304, "conditional GET with own validator")
            equal(cached.body, "", "304 response body empty")
        equal(fresh[0].header("last-modified"), fresh[1].header("last-modified"), "seed Last-Modified equal")
        return {"exact_window_counts": counts, "wrong_room_boundary_404": True,
                "wrong_room_deep_link_fallback": True, "conditional_get": True}

    def sidebar(self):
        evidence = []
        for user in ("david", "kevin"):
            full = self.both("/users/me/sidebar", user=user)
            self.compare(full)
            frame = self.both("/users/me/sidebar", user=user, headers={"Turbo-Frame": "user_sidebar"})
            self.compare(frame)
            uid = self.label("users." + user)
            memberships = rows(self.canonical_db, "SELECT r.id,r.type,r.name,r.updated_at FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND m.involvement != 'invisible' ORDER BY LOWER(r.name)", (uid,))
            direct = [r for r in memberships if r["type"] == "Rooms::Direct"]
            direct.sort(key=lambda r: r["updated_at"])
            direct.reverse()
            shared = [r for r in memberships if r["type"] != "Rooms::Direct"]
            for reply in full:
                check("<!doctype html>" in reply.body.lower(), "sidebar full application layout")
            for reply in frame:
                check("<!doctype" not in reply.body.lower(), "sidebar frame omits layout")
                sidebar = by_id(reply.dom, "user_sidebar")
                direct_links = by_id(sidebar, "direct_rooms").find(lambda n: n.tag == "a")
                shared_links = by_id(sidebar, "shared_rooms").find(lambda n: n.tag == "a")
                equal([n.attrs.get("href") for n in direct_links], [f'/rooms/{r["id"]}' for r in direct], "direct membership ordering by room touch descending")
                equal([n.attrs.get("href") for n in shared_links], [f'/rooms/{r["id"]}' for r in shared], "shared membership name ordering and invisibility")
            evidence.append({"user": user, "direct_ids": [r["id"] for r in direct], "shared_ids": [r["id"] for r in shared]})
        return {"membership_lists": evidence, "full_frame_and_placeholder_dom_parity": True}

    def history(self, conn, user):
        return rows(conn, "SELECT * FROM searches WHERE user_id=? ORDER BY id", (self.label("users." + user),))

    def search(self):
        evidence = []
        for user, query in (("david", "coffee"), ("david", "launch"), ("kevin", "coffee"),
                            ("jason", "approve"), ("david", "approve")):
            before = self.history(self.native_db, user)
            expected = rows(self.canonical_db, "SELECT m.id FROM messages m JOIN message_search_index idx ON idx.rowid=m.id JOIN memberships ms ON ms.room_id=m.room_id WHERE ms.user_id=? AND idx.body MATCH ? ORDER BY m.created_at DESC LIMIT 100", (self.label("users." + user), '"' + query + '"*'))
            expected_ids = [r["id"] for r in reversed(expected)]
            replies = self.both("/searches?" + urllib.parse.urlencode({"q": query}), user=user)
            self.compare(replies)
            for reply in replies:
                equal(message_ids(reply.dom), expected_ids, "search exact reachable live IDs in chronological order")
                equal(one(reply.dom, lambda n: n.tag == "title", "search title").text(), "Search", "real search layout")
            equal(self.history(self.native_db, user), before, "GET search never records/touches history")
            evidence.append({"user": user, "query": query, "ids": expected_ids})
        check(any(e["ids"] for e in evidence if e["user"] == "david" and e["query"] == "approve"), "reachable positive control for private message")
        equal(next(e["ids"] for e in evidence if e["user"] == "jason" and e["query"] == "approve"), [], "private room search denied to other user")
        frame = self.both("/searches?q=coffee", headers={"Turbo-Frame": "main-content"})
        self.compare(frame)
        for reply in frame:
            check("<!doctype" not in reply.body.lower(), "search frame has no layout")
            one(reply.dom, lambda n: n.tag == "html", "Rails search frame wrapper")
            by_id(reply.dom, "search-results")
            check(not reply.dom.find(lambda n: n.attrs.get("id") in {"nav", "sidebar", "footer"}), "search frame omits application navigation/sidebar/footer")
        return {"queries": evidence, "get_history_unchanged": True, "frame_dom_parity": True}

    def search_history(self):
        # Loner owns no canonical history. DELETE /clear affects only this isolated account.
        user = "loner"
        before_other = self.history(self.native_db, "david")
        query = self.run_id + ", query"
        normalized = self.run_id + "  query"
        before = self.history(self.native_db, user)
        equal(before, [], "dedicated history account must remain empty before mutation")
        self.compare(self.both("/searches?" + urllib.parse.urlencode({"q": query}), user=user))
        equal(self.history(self.native_db, user), before, "history GET without recording")
        posted = self.both("/searches", "POST", {"q": query}, user=user)
        self.compare(posted, 302, dom=False)
        for reply in posted:
            equal(urllib.parse.parse_qs(urllib.parse.urlsplit(reply.header("location")).query).get("q"), [normalized], "POST search redirects using normalized query")
        history = self.history(self.native_db, user)
        equal([r["query"] for r in history], [normalized], "POST actually persists normalized search")
        after_get = self.both("/searches", user=user)
        self.compare(after_get)
        for reply in after_get:
            check(reply.dom.find(lambda n: n.tag == "a" and urllib.parse.parse_qs(urllib.parse.urlsplit(n.attrs.get("href", "")).query).get("q") == [normalized]), "recorded search visible in consumer HTML")
        equal(self.history(self.native_db, user), history, "history display GET does not touch recorded row")
        self.compare(self.both("/searches/clear", "DELETE", user=user), 302, dom=False)
        equal(self.history(self.native_db, user), [], "DELETE search history persists clearing")
        equal(self.history(self.native_db, "david"), before_other, "history deletion cannot affect another user's data")
        if self.oracle_db:
            equal(self.history(self.oracle_db, user), [], "oracle isolated history cleared")
        return {"user": self.label("users.loner"), "recorded_query": normalized,
                "post_persistent": True, "delete_persistent": True, "other_user_unchanged": True}

    def stored_message(self, client_id):
        found = rows(self.native_db, "SELECT * FROM messages WHERE client_message_id=?", (client_id,))
        equal(len(found), 1, "HTTP write creates exactly one persistent message")
        return found[0]

    def write_message(self, suffix, body):
        room = self.label("rooms.designers")
        client_id = self.run_id + "-" + suffix
        before_members = rows(self.native_db, "SELECT * FROM memberships ORDER BY id")
        before_room = rows(self.native_db, "SELECT * FROM rooms WHERE id=?", (room,))[0]
        before_count = self.native_db.execute("SELECT count(*) FROM messages").fetchone()[0]
        replies = self.both(f"/rooms/{room}/messages", "POST", {"message[body]": body, "message[client_message_id]": client_id}, headers={"Accept": TURBO})
        for reply in replies:
            equal(reply.status, 200, "message POST status")
            equal(reply.header("content-type"), "text/vnd.turbo-stream.html; charset=utf-8", "message POST Turbo-stream MIME")
            stream = one(reply.dom, lambda n: n.tag == "turbo-stream", "real append Turbo stream")
            equal(stream.attrs, {"action": "append", "target": f"messages_rooms_closed_{room}"}, "stream action and actual room target")
            one(stream, lambda n: n.tag == "template", "Turbo stream template")
            equal(len(messages(stream)), 1, "Turbo stream carries actual message DOM")
            equal(messages(stream)[0].attrs.get("id"), "message_" + client_id, "Turbo client-message DOM id")
        stored = self.stored_message(client_id)
        equal(stored["creator_id"], self.label("users.david"), "stored authenticated author")
        equal(stored["room_id"], room, "stored room")
        equal(self.native_db.execute("SELECT count(*) FROM messages").fetchone()[0], before_count + 1, "one message inserted, none removed")
        equal(int(messages(replies[0].dom)[0].attrs["data-message-id"]), stored["id"], "returned live persistent message ID")
        self.validate_message_time(messages(replies[0].dom)[0], stored)
        rich = rows(self.native_db, "SELECT * FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'", (stored["id"],))
        equal(len(rich), 1, "persistent ActionText rich text row")
        check(self.run_id in rich[0]["body"], "rich text stores submitted marker")
        index = rows(self.native_db, "SELECT rowid,body FROM message_search_index WHERE rowid=?", (stored["id"],))
        equal(len(index), 1, "after-commit FTS row exists")
        check(self.run_id in index[0]["body"] and "<p>" not in index[0]["body"] and "<strong>" not in index[0]["body"], "FTS contains real plain text, not HTML")
        after_room = rows(self.native_db, "SELECT * FROM rooms WHERE id=?", (room,))[0]
        check(timestamp(after_room["updated_at"]) > timestamp(before_room["updated_at"]), "message callback touches room")
        check(timestamp(after_room["updated_at"]) >= timestamp(stored["created_at"]), "room touch covers new message time")
        equal({k: v for k, v in after_room.items() if k != "updated_at"}, {k: v for k, v in before_room.items() if k != "updated_at"}, "room touch changes no unrelated attributes")
        after_members = {r["id"]: r for r in rows(self.native_db, "SELECT * FROM memberships ORDER BY id")}
        equal(sorted(after_members), sorted(r["id"] for r in before_members), "message callback does not add/delete memberships")
        unread = []
        cutoff = timestamp(stored["created_at"]) - dt.timedelta(seconds=60)
        for member in before_members:
            after = after_members[member["id"]]
            disconnected = member["connected_at"] is None or timestamp(member["connected_at"]) < cutoff
            eligible = (member["room_id"] == room and member["user_id"] != stored["creator_id"]
                        and member["involvement"] is not None and member["involvement"] != "invisible" and disconnected)
            if eligible:
                equal(after["unread_at"], stored["created_at"], "room receive sets eligible non-author unread_at to message time")
                check(timestamp(after["updated_at"]) >= timestamp(stored["created_at"]), "unread callback touches membership")
                equal({k: v for k, v in after.items() if k not in {"unread_at", "updated_at"}},
                      {k: v for k, v in member.items() if k not in {"unread_at", "updated_at"}}, "unread callback preserves membership attributes")
                unread.append(member["id"])
            else:
                equal(after, member, "author/invisible/connected/unrelated memberships untouched")
        check(unread, "canonical post exercises real unread callbacks")
        # DB IDs must agree on fresh paired copies: do not normalize persistent identity differences.
        equal(int(messages(replies[1].dom)[0].attrs["data-message-id"]), stored["id"], "native created ID equals live Rust ID")
        self.compare_message(messages(replies[0].dom)[0], messages(replies[1].dom)[0], dynamic=True)
        if self.oracle_db:
            oracle_stored = rows(self.oracle_db, "SELECT * FROM messages WHERE client_message_id=?", (client_id,))
            equal(len(oracle_stored), 1, "oracle persistent message")
            equal({k: v for k, v in oracle_stored[0].items() if k not in {"created_at", "updated_at"}},
                  {k: v for k, v in stored.items() if k not in {"created_at", "updated_at"}}, "native/oracle persistent message fields")
            oracle_rich = rows(self.oracle_db, "SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=? AND name='body'", (stored["id"],))
            equal([{"body": rich[0]["body"]}], oracle_rich, "native/oracle canonical stored rich text")
            equal(index, rows(self.oracle_db, "SELECT rowid,body FROM message_search_index WHERE rowid=?", (stored["id"],)), "native/oracle plain-text FTS")
        return replies, stored, index[0]["body"], unread

    def validate_message_time(self, node, stored):
        equal(node.attrs.get("data-message-timestamp"), str(epoch_ms(stored["created_at"])), "DOM timestamp represents persistent created_at")
        equal(node.attrs.get("data-message-updated-at"), str(epoch_ms(stored["updated_at"])), "DOM updated timestamp represents persistent updated_at")
        equal(node.attrs.get("data-sort-value"), str(epoch_ms(stored["created_at"])), "DOM sort timestamp represents persistent created_at")
        times = node.find(lambda n: n.tag == "time")
        check(times, "posted message exposes real time elements")
        for element in times:
            equal(element.attrs.get("datetime"), timestamp(stored["created_at"]).strftime("%Y-%m-%dT%H:%M:%SZ"), "DOM datetime uses persistent time at Rails seconds precision")

    def read_back(self, stored):
        room = stored["room_id"]
        result = []
        for path in (f"/rooms/{room}", "/searches?" + urllib.parse.urlencode({"q": self.run_id})):
            replies = self.both(path)
            for reply in replies:
                equal(reply.status, 200, "posted message read-back status")
                equal(message_ids(reply.dom).count(stored["id"]), 1, "posted message discoverable exactly once")
            native = next(n for n in messages(replies[0].dom) if int(n.attrs["data-message-id"]) == stored["id"])
            oracle = next(n for n in messages(replies[1].dom) if int(n.attrs["data-message-id"]) == stored["id"])
            self.validate_message_time(native, stored)
            self.compare_message(native, oracle, dynamic=True)
            result.append((native, oracle))
        return result

    def message_write(self):
        body = f"<p>{self.run_id} Hello <strong>there</strong> &amp; goodbye</p>"
        replies, stored, plain, unread = self.write_message("safe", body)
        equal(plain, f"{self.run_id} Hello there & goodbye", "exact ActionText plain-text indexing")
        for reply in replies:
            strong = presentation(messages(reply.dom)[0]).find(lambda n: n.tag == "strong")
            equal([n.text() for n in strong], ["there"], "submitted strong formatting renders, not escaped or stripped")
        readbacks = self.read_back(stored)
        for native, _ in readbacks:
            equal(canonical(presentation(native), self.args.base), canonical(presentation(messages(replies[0].dom)[0]), self.args.base), "posted body rendered identically on read-back and search")
        return {"message_id": stored["id"], "client_message_id": stored["client_message_id"],
                "plain_text": plain, "unread_membership_ids": unread,
                "real_turbo_body": True, "room_read_back": True, "search_discoverability": True}

    def unsafe_richtext(self):
        body = (f'<p>{self.run_id} safe <strong>bold</strong></p>'
                '<script>window.nativeGatePwned=1</script>'
                '<iframe src="https://evil.example/">unsafe frame</iframe>'
                '<a href="javascript:alert(1)" onmouseover="alert(2)">unsafe link</a>'
                '<img src="x" onerror="alert(3)">'
                '<a href="data:text/html,pwned">unsafe data link</a>'
                '<p title="x> http://evil.test/ <img src=x onerror=alert(1)>">attribute boundary</p>'
                '<a href="https://example.com/safe" onclick="alert(4)">safe link</a>')
        # The suite advances its clock by a second for touch assertions. Real servers
        # need an actual clock boundary when native timestamps have seconds precision.
        time.sleep(1.05)
        replies, stored, plain, unread = self.write_message("unsafe", body)
        consumers = [messages(reply.dom)[0] for reply in replies]
        for native, oracle in self.read_back(stored):
            consumers.extend((native, oracle))
        for message in consumers:
            rendered = presentation(message)
            check(self.run_id in rendered.text(), "sanitization retains safe message text")
            equal([n.text() for n in rendered.find(lambda n: n.tag == "strong")], ["bold"], "sanitization retains allowed formatting")
            check(not rendered.find(lambda n: n.tag in {"script", "iframe", "object", "embed", "svg", "img"}), "consumer richtext has no executable/foreign/unattached-image elements", [], [n.tag for n in rendered.walk()])
            for node in rendered.walk():
                for name, value in node.attrs.items():
                    check(not name.lower().startswith("on"), "consumer richtext has no event-handler attributes", None, {name: value})
                    if name in {"href", "src", "xlink:href", "action"} and value:
                        compact = re.sub(r"[\x00-\x20]", "", value).lower()
                        check(not compact.startswith(("javascript:", "vbscript:", "data:text/html")), "consumer URL protocol is safe", None, value)
            equal([n.attrs.get("href") for n in rendered.find(lambda n: n.tag == "a" and n.text() == "safe link")], ["https://example.com/safe"], "sanitizer preserves allowed safe link")
        return {"message_id": stored["id"], "consumers_checked": ["Turbo POST", "room GET", "search GET"],
                "unsafe_tags_events_protocols_removed": True, "allowed_text_formatting_link_retained": True,
                "plain_text": plain, "unread_membership_ids": unread}

    def report(self):
        passed = len(self.results) == len(ANCHORS) and all(r["status"] == "pass" for r in self.results)
        return {"schema": "campfire-native-http-contract/v1", "scope": "five-path leaderboard conformance subset with authentication/history prerequisites",
                "whole_campfire_suite_passed": False, "gate_passed": passed,
                "run_id": self.run_id, "base": self.args.base, "oracle": self.args.oracle,
                "oracle_image_required": "ccece30e8e160d8c3e05bf395ee55ee35962093b",
                "normalization": ["server origin", "CSRF masks", "CSP nonce", "new message timestamps only", "non-content serialization indentation and attribute order"],
                "coverage": {"GET /rooms/:id": ["full/frame DOM", "membership denial", "last/around windows", "wrong-room deep links"],
                             "GET /rooms/:id/messages": ["exact 40 before/after/last ordered IDs", "boundary 204", "wrong-room 404", "conditional GET"],
                             "GET /users/me/sidebar": ["full/frame DOM", "visible memberships", "shared name/direct timestamp order", "placeholders"],
                             "GET /searches?q=...": ["reachable-only results", "exact IDs/order/content", "no history mutation", "frame DOM", "posted-message discoverability"],
                             "POST /rooms/:id/messages": ["actual Turbo append body", "persistent message/richtext/FTS", "room touch/unread callbacks", "read-back", "unsafe consumer richtext"],
                             "prerequisites": ["fresh isolated seed copies", "real password login/rejection", "Rails-issued/forged cookie", "refresh/logout", "POST/DELETE search history"]},
                "not_covered": ["whole Campfire suite", "websocket broadcasts", "push delivery/jobs", "uploads", "edit/delete/boost mutation", "browser visual behavior", "performance"],
                "scenarios": self.results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="native HTTP origin, e.g. http://127.0.0.1:4200")
    parser.add_argument("--oracle", required=True, help="live Rust HTTP origin (fixed ccece30 image)")
    parser.add_argument("--seed", required=True, help="canonical seed directory containing labels.json and db/production.sqlite3")
    parser.add_argument("--db", required=True, help="native server's dedicated writable SQLite copy (runner opens read-only)")
    parser.add_argument("--oracle-db", help="optional Rust server SQLite copy for additional persistent-state parity")
    parser.add_argument("--timeout", type=float, default=15, help="finite timeout per HTTP request in seconds (default 15)")
    parser.add_argument("--output", help="also save machine-readable JSON to this file")
    args = parser.parse_args()
    for key in ("base", "oracle"):
        value = getattr(args, key).rstrip("/")
        url = urllib.parse.urlsplit(value)
        if url.scheme not in {"http", "https"} or not url.netloc or url.username or url.password or url.path or url.query or url.fragment:
            parser.error(f"--{key} must be an HTTP(S) origin without credentials/path/query")
        setattr(args, key, value)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    gate = None
    try:
        gate = Gate(args)
        ready = gate.run("prerequisites", gate.prerequisites)
        if ready:
            for name in ANCHORS:
                if name != "prerequisites":
                    gate.run(name, getattr(gate, name))
        else:
            for name in ANCHORS:
                if name != "prerequisites":
                    gate.results.append({"scenario": name, "status": "blocked", "source_anchors": ANCHORS[name],
                                         "evidence": {"assertion": "fresh isolated canonical dataset prerequisite failed"}, "requests": []})
        report = gate.report()
    except Exception as error:
        report = {"schema": "campfire-native-http-contract/v1", "whole_campfire_suite_passed": False,
                  "gate_passed": False, "error_type": type(error).__name__, "error": str(error)}
    finally:
        if gate:
            for conn in (gate.canonical_db, gate.native_db, gate.oracle_db):
                if conn:
                    conn.close()
    output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        Path(args.output).write_text(output)
    sys.stdout.write(output)
    return 0 if report["gate_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
