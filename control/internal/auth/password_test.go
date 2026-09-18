package auth

import (
	"strings"
	"testing"
)

func TestPasswordHashingAndValidation(t *testing.T) {
	const password = "correct horse battery staple"

	hash, err := HashPassword(password)
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if hash == password || strings.Contains(hash, password) {
		t.Fatal("password hash contains the raw password")
	}
	if !VerifyPassword(hash, password) {
		t.Fatal("valid password did not verify")
	}
	if VerifyPassword(hash, "incorrect horse battery staple") {
		t.Fatal("incorrect password verified")
	}

	for _, password := range []string{"too short", strings.Repeat("x", 1025)} {
		if _, err := HashPassword(password); err == nil {
			t.Fatalf("HashPassword accepted invalid password length %d", len(password))
		}
	}
	if VerifyPassword("not-an-argon2-hash", password) {
		t.Fatal("malformed password hash verified")
	}
}
