package main

import (
	"database/sql"
	"errors"
	"os"
	"strconv"

	_ "github.com/mattn/go-sqlite3"
)

const (
	databasePath     = "/tmp/z-notes-benchmark-wails.sqlite3"
	benchmarkControl = "/tmp/z-notes-benchmark-wails.control"
	benchmarkReady   = "/tmp/z-notes-benchmark-wails.ready"
	benchmarkResult  = "/tmp/z-notes-benchmark-wails.result.json"
)

type Note struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Body  string `json:"body"`
}

type CreateNoteInput struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type BenchmarkReport struct {
	Phase   string `json:"phase"`
	Payload string `json:"payload"`
}

type NotesService struct{}

func openDatabase() (*sql.DB, error) {
	database, err := sql.Open("sqlite3", databasePath)
	if err != nil {
		return nil, err
	}
	database.SetMaxOpenConns(1)
	_, err = database.Exec(`
CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL
);
INSERT OR IGNORE INTO notes (id, title, body) VALUES
  (1, 'Welcome to Z Notes', 'A native notes application implemented across desktop frameworks.'),
  (2, 'One workload', 'The frontend, storage behavior, and workflow stay equivalent.');
`)
	if err != nil {
		database.Close()
		return nil, err
	}
	return database, nil
}

func (service *NotesService) List() ([]Note, error) {
	database, err := openDatabase()
	if err != nil {
		return nil, err
	}
	defer database.Close()

	rows, err := database.Query("SELECT id, title, body FROM notes ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	notes := make([]Note, 0)
	for rows.Next() {
		var id int64
		var title string
		var body string
		if err := rows.Scan(&id, &title, &body); err != nil {
			return nil, err
		}
		notes = append(notes, Note{
			ID:    strconv.FormatInt(id, 10),
			Title: title,
			Body:  body,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return notes, nil
}

func (service *NotesService) Create(input CreateNoteInput) (Note, error) {
	if input.Title == "" {
		return Note{}, errors.New("a note title is required")
	}
	database, err := openDatabase()
	if err != nil {
		return Note{}, err
	}
	defer database.Close()

	var id int64
	if err := database.QueryRow(
		"SELECT COALESCE(MAX(id), 0) + 1 FROM notes",
	).Scan(&id); err != nil {
		return Note{}, err
	}
	if _, err := database.Exec(
		"INSERT INTO notes (id, title, body) VALUES (?, ?, ?)",
		id,
		input.Title,
		input.Body,
	); err != nil {
		return Note{}, err
	}
	return Note{
		ID:    strconv.FormatInt(id, 10),
		Title: input.Title,
		Body:  input.Body,
	}, nil
}

func (service *NotesService) BenchmarkMode() bool {
	_, err := os.Stat(benchmarkControl)
	return err == nil
}

func (service *NotesService) ReportBenchmark(report BenchmarkReport) (bool, error) {
	path := benchmarkResult
	if report.Phase == "ready" {
		path = benchmarkReady
	}
	if err := os.WriteFile(path, []byte(report.Payload), 0o644); err != nil {
		return false, err
	}
	return true, nil
}
