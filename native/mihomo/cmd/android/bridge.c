#include <jni.h>
#include <stdlib.h>
#include "_cgo_export.h"

JNIEXPORT jstring JNICALL
Java_org_antirkn_antirkn_1manager_MihomoValidationService_validateNative(
    JNIEnv *env, jobject self, jbyteArray request, jstring directory) {
  jsize count = (*env)->GetArrayLength(env, request);
  if (count < 0 || count > 16 * 1024 * 1024) return NULL;
  char *input = calloc((size_t)count + 1, 1);
  if (!input) return NULL;
  (*env)->GetByteArrayRegion(env, request, 0, count, (jbyte *)input);
  const char *path = (*env)->GetStringUTFChars(env, directory, NULL);
  if (!path) { free(input); return NULL; }
  char *output = antirknValidate(input, (char *)path);
  (*env)->ReleaseStringUTFChars(env, directory, path);
  free(input);
  if (!output) return NULL;
  jstring result = (*env)->NewStringUTF(env, output);
  free(output);
  return result;
}
