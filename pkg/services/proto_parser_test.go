package services

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"
)

// MockServerProfileStore is a mock implementation of ServerProfileStore
type MockServerProfileStore struct {
	mock.Mock
}

func (m *MockServerProfileStore) CreateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error {
	args := m.Called(ctx, def)
	return args.Error(0)
}

func (m *MockServerProfileStore) UpdateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error {
	args := m.Called(ctx, def)
	return args.Error(0)
}

func (m *MockServerProfileStore) DeleteProtoDefinition(ctx context.Context, id string) error {
	args := m.Called(ctx, id)
	return args.Error(0)
}

func (m *MockServerProfileStore) GetProtoDefinition(ctx context.Context, id string) (*proto.ProtoDefinition, error) {
	args := m.Called(ctx, id)
	return args.Get(0).(*proto.ProtoDefinition), args.Error(1)
}

func (m *MockServerProfileStore) ListProtoDefinitions(ctx context.Context) ([]*proto.ProtoDefinition, error) {
	args := m.Called(ctx)
	return args.Get(0).([]*proto.ProtoDefinition), args.Error(1)
}

func (m *MockServerProfileStore) ListProtoDefinitionsByProfile(ctx context.Context, serverProfileId string) ([]*proto.ProtoDefinition, error) {
	args := m.Called(ctx, serverProfileId)
	return args.Get(0).([]*proto.ProtoDefinition), args.Error(1)
}

// Required interface methods that we don't need for testing
func (m *MockServerProfileStore) Create(ctx context.Context, profile *models.ServerProfile) error {
	return nil
}

func (m *MockServerProfileStore) Get(ctx context.Context, id string) (*models.ServerProfile, error) {
	return nil, nil
}

func (m *MockServerProfileStore) List(ctx context.Context) ([]*models.ServerProfile, error) {
	return nil, nil
}

func (m *MockServerProfileStore) Update(ctx context.Context, profile *models.ServerProfile) error {
	return nil
}

func (m *MockServerProfileStore) Delete(ctx context.Context, id string) error {
	return nil
}

func (m *MockServerProfileStore) CreateProtoPath(ctx context.Context, path *proto.ProtoPath) error {
	return nil
}

func (m *MockServerProfileStore) GetProtoPath(ctx context.Context, id string) (*proto.ProtoPath, error) {
	return nil, nil
}

func (m *MockServerProfileStore) UpdateProtoPath(ctx context.Context, path *proto.ProtoPath) error {
	return nil
}

func (m *MockServerProfileStore) ListProtoPathsByServer(ctx context.Context, serverID string) ([]*proto.ProtoPath, error) {
	return nil, nil
}

func (m *MockServerProfileStore) DeleteProtoPath(ctx context.Context, id string) error {
	return nil
}

func (m *MockServerProfileStore) ListProtoDefinitionsByProtoPath(ctx context.Context, protoPathID string) ([]*proto.ProtoDefinition, error) {
	return nil, nil
}

func (m *MockServerProfileStore) UpsertPerRequestHeaders(ctx context.Context, h *models.PerRequestHeaders) error {
	return nil
}

func (m *MockServerProfileStore) GetPerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) (*models.PerRequestHeaders, error) {
	return nil, nil
}

func (m *MockServerProfileStore) DeletePerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) error {
	return nil
}

func TestProtoParser_ScanAndParseProtoPath(t *testing.T) {
	// Create a temporary directory for test proto files
	tempDir, err := os.MkdirTemp("", "proto-test-*")
	assert.NoError(t, err)
	defer os.RemoveAll(tempDir)

	// Create a test proto file
	testProtoContent := `
syntax = "proto3";

package test;

service TestService {
  rpc TestMethod (TestRequest) returns (TestResponse) {}
}

message TestRequest {
  string name = 1;
}

message TestResponse {
  string message = 1;
}

enum TestEnum {
  UNKNOWN = 0;
  VALUE_1 = 1;
  VALUE_2 = 2;
}
`
	testProtoPath := filepath.Join(tempDir, "test.proto")
	err = os.WriteFile(testProtoPath, []byte(testProtoContent), 0644)
	assert.NoError(t, err)

	// Create mock store
	mockStore := new(MockServerProfileStore)
	parser := NewProtoParser(mockStore)

	// Test case: successful parsing and storage
	t.Run("successful parsing and storage", func(t *testing.T) {
		ctx := context.Background()
		serverProfileId := "test-profile-id"
		protoPathId := "test-path-id"

		// Set up mock expectations
		mockStore.On("ListProtoDefinitionsByProfile", ctx, serverProfileId).Return([]*proto.ProtoDefinition{}, nil)
		mockStore.On("CreateProtoDefinition", ctx, mock.AnythingOfType("*proto.ProtoDefinition")).Return(nil)

		// Execute test
		err := parser.ScanAndParseProtoPath(ctx, serverProfileId, protoPathId, tempDir)
		assert.NoError(t, err)

		// Verify mock expectations
		mockStore.AssertExpectations(t)
	})

	// Test case: existing definition update
	t.Run("existing definition update", func(t *testing.T) {
		ctx := context.Background()
		serverProfileId := "test-profile-id"
		protoPathId := "test-path-id"

		// Create a new mock store for this test case
		mockStore = new(MockServerProfileStore)
		parser = NewProtoParser(mockStore)

		// Remove leading slash to match parser's fileDesc.GetName()
		relPath := testProtoPath
		if strings.HasPrefix(relPath, "/") {
			relPath = relPath[1:]
		}
		existingDef := &proto.ProtoDefinition{
			ID:              "existing-id",
			FilePath:        relPath, // Match parser's fileDesc.GetName()
			ServerProfileID: serverProfileId,
			ProtoPathID:     protoPathId,
		}

		// Set up mock expectations
		mockStore.On("ListProtoDefinitionsByProfile", ctx, serverProfileId).Return([]*proto.ProtoDefinition{existingDef}, nil)
		mockStore.On("UpdateProtoDefinition", ctx, mock.MatchedBy(func(def *proto.ProtoDefinition) bool {
			return def.FilePath == relPath && def.ServerProfileID == serverProfileId && def.ProtoPathID == protoPathId
		})).Return(nil)

		// Execute test
		err := parser.ScanAndParseProtoPath(ctx, serverProfileId, protoPathId, tempDir)
		assert.NoError(t, err)

		// Verify mock expectations
		mockStore.AssertExpectations(t)
	})

	// Test case: invalid proto file
	t.Run("invalid proto file", func(t *testing.T) {
		ctx := context.Background()
		serverProfileId := "test-profile-id"
		protoPathId := "test-path-id"

		// Create a new mock store for this test case
		mockStore = new(MockServerProfileStore)
		parser = NewProtoParser(mockStore)

		// Create an invalid proto file
		invalidProtoContent := `invalid proto content`
		invalidProtoPath := filepath.Join(tempDir, "invalid.proto")
		err = os.WriteFile(invalidProtoPath, []byte(invalidProtoContent), 0644)
		assert.NoError(t, err)

		// Set up mock expectations
		mockStore.On("ListProtoDefinitionsByProfile", ctx, serverProfileId).Return([]*proto.ProtoDefinition{}, nil)
		mockStore.On("CreateProtoDefinition", ctx, mock.AnythingOfType("*proto.ProtoDefinition")).Return(nil)

		// Execute test
		err := parser.ScanAndParseProtoPath(ctx, serverProfileId, protoPathId, tempDir)
		assert.NoError(t, err) // The parser should continue even if one file fails

		// Verify mock expectations
		mockStore.AssertExpectations(t)
	})
}
