import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_home_endpoint():
    """Test głównego endpointu"""
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "Formularz Ankiety" in response.text


def test_health_endpoint():
    """Test endpointu zdrowia"""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert "status" in data
    assert "database" in data
    assert data["status"] in ["healthy", "unhealthy"]


def test_submit_endpoint_with_invalid_data():
    """Test endpointu submit z niepoprawnymi danymi"""
    response = client.post("/submit", data={})
    # Powinien zwrócić błąd walidacji (422 Unprocessable Entity)
    assert response.status_code == 422


def test_submit_endpoint_with_valid_data():
    """Test endpointu submit z poprawnymi danymi"""
    form_data = {
        "question": "Jak oceniasz usługę?",
        "answer": "Bardzo dobrze"
    }
    response = client.post("/submit", data=form_data)
    # Sprawdzamy czy strona się ładuje
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_multiple_questions():
    """Test sprawdzający różne pytania"""
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    for question in questions:
        form_data = {
            "question": question,
            "answer": "Test odpowiedź"
        }
        response = client.post("/submit", data=form_data)
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]


def test_form_contains_all_questions():
    """Test czy formularz zawiera wszystkie pytania"""
    response = client.get("/")
    content = response.text
    assert "Jak oceniasz usługę?" in content
    assert "Czy polecisz nas?" in content
    assert "Jak często korzystasz?" in content


def test_form_has_correct_structure():
    """Test struktury formularza"""
    response = client.get("/")
    content = response.text
    assert 'name="question"' in content
    assert 'name="answer"' in content
    assert 'method="post"' in content
    assert 'action="/submit"' in content


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
