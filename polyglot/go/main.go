package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mattn/go-sqlite3"
)

type Item struct {
	ID        int64   `json:"id"`
	Code      string  `json:"code"`
	Name      string  `json:"name"`
	Category  string  `json:"category"`
	Price     float64 `json:"price"`
	Counter   int64   `json:"counter"`
	Notes     string  `json:"notes"`
	UpdatedAt int64   `json:"updated_at"`
}

type UpdateResponse struct {
	ID        int64 `json:"id"`
	Updated   int   `json:"updated"`
	UpdatedAt int64 `json:"updated_at"`
}

type HealthResponse struct {
	Status string `json:"status"`
	Mode   string `json:"mode"`
	Go     string `json:"go"`
	Driver string `json:"driver"`
	SQLite string `json:"sqlite"`
}

func isBusyOrLocked(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "locked") || strings.Contains(s, "busy")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"error":"marshal failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json;charset=UTF-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.WriteHeader(status)
	_, _ = w.Write(b)
}

func main() {
	var (
		port     int
		workers  int
		dbPath   string
		rowCount int
	)
	flag.IntVar(&port, "port", 3000, "TCP port to listen on")
	flag.IntVar(&workers, "workers", 4, "Worker / GOMAXPROCS / DB pool concurrency")
	flag.StringVar(&dbPath, "db", os.Getenv("DBI_BENCH_DB"), "Path to SQLite database")
	flag.IntVar(&rowCount, "rows", 10000, "Row count in items table")
	flag.Parse()

	if dbPath == "" {
		log.Fatal("missing --db or DBI_BENCH_DB")
	}
	if workers < 1 {
		workers = 1
	}
	if rowCount < 1 {
		rowCount = 10000
	}

	runtime.GOMAXPROCS(workers)

	sql.Register("sqlite3_bench", &sqlite3.SQLiteDriver{
		ConnectHook: func(conn *sqlite3.SQLiteConn) error {
			pragmas := []string{
				"PRAGMA busy_timeout = 15000",
				"PRAGMA journal_mode = WAL",
				"PRAGMA synchronous = NORMAL",
				"PRAGMA temp_store = MEMORY",
				"PRAGMA cache_size = -16000",
			}
			for _, p := range pragmas {
				if _, err := conn.Exec(p, nil); err != nil {
					return err
				}
			}
			return nil
		},
	})

	dsn := fmt.Sprintf("file:%s?_txlock=immediate&_busy_timeout=15000", dbPath)
	db, err := sql.Open("sqlite3_bench", dsn)
	if err != nil {
		log.Fatalf("sql.Open failed: %v", err)
	}
	defer db.Close()

	db.SetMaxOpenConns(workers)
	db.SetMaxIdleConns(workers)
	db.SetConnMaxLifetime(0)

	var sqliteVer string
	if err := db.QueryRow("SELECT sqlite_version()").Scan(&sqliteVer); err != nil {
		log.Fatalf("sqlite_version query failed: %v", err)
	}

	stmtSingle, err := db.Prepare(
		"SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id = ?",
	)
	if err != nil {
		log.Fatalf("prepare single failed: %v", err)
	}
	defer stmtSingle.Close()

	stmtRange, err := db.Prepare(
		"SELECT id, code, name, category, price, counter, notes, updated_at FROM items WHERE id >= ? AND id < ? ORDER BY id",
	)
	if err != nil {
		log.Fatalf("prepare range failed: %v", err)
	}
	defer stmtRange.Close()

	stmtUpdate, err := db.Prepare(
		"UPDATE items SET counter = counter + 1, updated_at = ? WHERE id = ?",
	)
	if err != nil {
		log.Fatalf("prepare update failed: %v", err)
	}
	defer stmtUpdate.Close()

	maxStart := 1
	if rowCount > 50 {
		maxStart = rowCount - 50
	}

	healthBytes, err := json.Marshal(HealthResponse{
		Status: "ok",
		Mode:   "go",
		Go:     runtime.Version(),
		Driver: "github.com/mattn/go-sqlite3",
		SQLite: sqliteVer,
	})
	if err != nil {
		log.Fatalf("marshal health failed: %v", err)
	}
	healthLen := strconv.Itoa(len(healthBytes))

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json;charset=UTF-8")
		w.Header().Set("Content-Length", healthLen)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(healthBytes)
	})

	mux.HandleFunc("/db/single", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		id := rand.IntN(rowCount) + 1
		var item Item
		err := stmtSingle.QueryRow(id).Scan(
			&item.ID, &item.Code, &item.Name, &item.Category,
			&item.Price, &item.Counter, &item.Notes, &item.UpdatedAt,
		)
		if err == sql.ErrNoRows {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, item)
	})

	mux.HandleFunc("/db/queries", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		n := 20
		if raw := r.URL.Query().Get("n"); raw != "" {
			if parsed, err := strconv.Atoi(raw); err == nil {
				n = parsed
			}
		}
		if n < 1 {
			n = 1
		}
		if n > 500 {
			n = 500
		}

		items := make([]Item, n)
		for i := 0; i < n; i++ {
			id := rand.IntN(rowCount) + 1
			err := stmtSingle.QueryRow(id).Scan(
				&items[i].ID, &items[i].Code, &items[i].Name, &items[i].Category,
				&items[i].Price, &items[i].Counter, &items[i].Notes, &items[i].UpdatedAt,
			)
			if err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
				return
			}
		}
		writeJSON(w, http.StatusOK, items)
	})

	mux.HandleFunc("/db/range", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		start := rand.IntN(maxStart) + 1
		end := start + 50
		rows, err := stmtRange.Query(start, end)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()

		items := make([]Item, 0, 50)
		for rows.Next() {
			var item Item
			if err := rows.Scan(
				&item.ID, &item.Code, &item.Name, &item.Category,
				&item.Price, &item.Counter, &item.Notes, &item.UpdatedAt,
			); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
				return
			}
			item.Code = strings.TrimRight(item.Code, " ")
			item.Category = strings.TrimRight(item.Category, " ")
			item.Notes = strings.TrimRight(item.Notes, " ")
			items = append(items, item)
		}
		if err := rows.Err(); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, items)
	})

	mux.HandleFunc("/db/update", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		_ = r.Body.Close()

		id := int64(rand.IntN(rowCount) + 1)
		ts := time.Now().Unix()

		var lastErr error
		for attempt := 1; attempt <= 20; attempt++ {
			tx, err := db.Begin()
			if err != nil {
				lastErr = err
				if isBusyOrLocked(err) && attempt < 20 {
					time.Sleep(time.Duration(2*attempt) * time.Millisecond)
					continue
				}
				break
			}
			txStmt := tx.Stmt(stmtUpdate)
			_, err = txStmt.Exec(ts, id)
			_ = txStmt.Close()
			if err != nil {
				_ = tx.Rollback()
				lastErr = err
				if isBusyOrLocked(err) && attempt < 20 {
					time.Sleep(time.Duration(2*attempt) * time.Millisecond)
					continue
				}
				break
			}
			if err = tx.Commit(); err != nil {
				_ = tx.Rollback()
				lastErr = err
				if isBusyOrLocked(err) && attempt < 20 {
					time.Sleep(time.Duration(2*attempt) * time.Millisecond)
					continue
				}
				break
			}
			lastErr = nil
			break
		}

		if lastErr != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": lastErr.Error()})
			return
		}
		writeJSON(w, http.StatusOK, UpdateResponse{
			ID:        id,
			Updated:   1,
			UpdatedAt: ts,
		})
	})

	srv := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", port),
		Handler: mux,
	}

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stopCh
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("ListenAndServe failed: %v", err)
	}
}
