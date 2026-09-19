# -*- coding: utf-8 -*-
"""一次性迁移：把 data/uploads/images/<yyyy-mm>/* 按题目分类归档到 <cid>/<yyyy-mm>/。

用法: python scripts/migrate_images.py [--dry-run]
规则: 每张图的分类 = 引用它的题目的 MIN(category_id)（跨分类共用图取最小并向用户报告）。
"""
import json
import os
import shutil
import sqlite3
import sys

DRY = "--dry-run" in sys.argv
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "data", "crm.db")
IMG_ROOT = os.path.join(ROOT, "data", "uploads", "images")
OLD_PREFIX = "/uploads/images/"
COLS = ("stem", "options", "explanation")


def main():
    con = sqlite3.connect(DB, timeout=20)
    cur = con.cursor()

    # 收集 2026-09 旧格式（无前导分类段）的图片 URL 集合，直接枚举磁盘文件推导
    old_files = {}  # filename -> month dir
    for month in sorted(os.listdir(IMG_ROOT)):
        mdir = os.path.join(IMG_ROOT, month)
        if not os.path.isdir(mdir) or not month[:2].isdigit():
            continue  # 已经是分类段(数字)或 misc 的目录跳过顶层判断
        # 顶层若是 "yyyy-mm" 形式(如 2026-09)才是要迁移的旧月子目录
        if len(month) == 7 and month[4] == "-":
            for f in os.listdir(mdir):
                old_files[f] = month

    print(f"旧目录中图片文件: {len(old_files)}")

    # 每张图 -> 引用它的题目分类集合
    img_cats = {}
    img_rows = {}
    for fname, month in old_files.items():
        old_url = f"{OLD_PREFIX}{month}/{fname}"
        like = f"%{old_url}%"
        ids = cur.execute(
            "select distinct category_id from questions "
            "where stem like ?1 or options like ?1 or explanation like ?1",
            (like,),
        ).fetchall()
        cats = sorted(r[0] for r in ids)
        img_cats[fname] = cats
        img_rows[fname] = old_url

    moved = reused = unref = shared = 0
    for fname, month in sorted(old_files.items(), key=lambda kv: kv[1]):
        cats = img_cats[fname]
        old_url = img_rows[fname]
        if not cats:
            unref += 1
            print(f"未引用，KEEP 原地: {old_url}")
            continue
        cid = cats[0]
        if len(cats) > 1:
            shared += 1
            print(f"跨分类共用: {fname} -> 选 {cid}，全部={cats}")
        new_month_dir = os.path.join(IMG_ROOT, str(cid), month)
        new_rel = f"{OLD_PREFIX}{cid}/{month}/{fname}"
        old_path = os.path.join(IMG_ROOT, month, fname)
        new_path = os.path.join(new_month_dir, fname)
        if not DRY:
            os.makedirs(new_month_dir, exist_ok=True)
            if os.path.exists(new_path):
                reused += 1
                os.remove(old_path)
            else:
                shutil.move(old_path, new_path)
            for col in COLS:
                cur.execute(
                    f"update questions set {col}=replace({col}, ?, ?) "
                    f"where {col} like ?",
                    (old_url, new_rel, f"%{old_url}%"),
                )
        moved += 1

    if not DRY:
        con.commit()
    con.close()

    # 清掉空的旧月子目录
    if not DRY:
        for month in sorted(os.listdir(IMG_ROOT)):
            mdir = os.path.join(IMG_ROOT, month)
            if (
                os.path.isdir(mdir)
                and len(month) == 7 and month[4] == "-"
                and not os.listdir(mdir)
            ):
                os.rmdir(mdir)
                print(f"删除空目录: {mdir}")

    mode = "DRY-RUN" if DRY else "已迁移"
    print(f"{mode}: moved={moved} 目标已存在去重={reused} 跨分类共用={shared} 未引用={unref}")


if __name__ == "__main__":
    main()
