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


def test_prometheus_metrics_endpoint():
    """Test endpointu metryk Prometheusa"""
    response = client.get("/metrics")
    assert response.status_code == 200
    # Sprawdzamy czy odpowiedź zawiera typowe metryki Prometheusa
    content = response.text
    assert "http_request" in content or "process_cpu" in content or "python_gc" in content


def test_submit_endpoint_with_invalid_data():
    """Test endpointu submit z niepoprawnymi danymi"""
    response = client.post("/submit", data={})
    # Powinien zwrócić błąd walidacji (422 Unprocessable Entity)
    assert response.status_code == 422


def test_submit_endpoint_with_valid_data():
    """Test endpointu submit z poprawnymi danymi"""
    form_data = {"question": "Jak oceniasz usługę?", "answer": "Bardzo dobrze"}
    response = client.post("/submit", data=form_data)
    # Sprawdzamy czy strona się ładuje (może być 200 nawet przy błędzie DB w testach)
    assert response.status_code == 200
<<<<<<< HEAD


def test_prometheus_metrics_available():
    """Test czy endpoint metryk Prometheusa jest dostępny"""
    response = client.get("/metrics")
    assert response.status_code == 200


@pytest.fixture
def sample_form_data():
    """Fixture z przykładowymi danymi formularza"""
    return {"question": "Czy polecisz nas?", "answer": "Tak"}
=======
    assert "text/html" in response.headers["content-type"]
>>>>>>> 547378a (deep17sh02 monitoring prometheus grafana loki tempo)


def test_multiple_questions():
    """Test sprawdzający różne pytania"""
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    for question in questions:
        form_data = {"question": question, "answer": "Test odpowiedź"}
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


@pytest.fixture
def sample_form_data():
    """Fixture z przykładowymi danymi formularza"""
    return {
        "question": "Czy polecisz nas?",
        "answer": "Tak"
    }


def test_submit_with_fixture(sample_form_data):
    """Test używający fixture"""
    response = client.post("/submit", data=sample_form_data)
    assert response.status_code == 200


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
