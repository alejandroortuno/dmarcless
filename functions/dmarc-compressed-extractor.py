from __future__ import print_function

import email
import zipfile
import os
import gzip
import string
import boto3
import urllib

print('Loading function')

s3 = boto3.client('s3')
s3r = boto3.resource('s3')
TMP_DIR = "/tmp/output/"

OUTPUT_BUCKET_NAME = os.environ['OUTPUT_BUCKET_NAME']
OUTPUT_BUCKET_PREFIX = "xml/"  # Should end with /


def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.unquote_plus(event['Records'][0]['s3']['object']['key']).decode('utf8')

    try:
        # Set OUTPUT_BUCKET_NAME if required
        if not OUTPUT_BUCKET_NAME:
            global OUTPUT_BUCKET_NAME
            OUTPUT_BUCKET_NAME = bucket

        # Use waiter to ensure the file is persisted
        waiter = s3.get_waiter('object_exists')
        waiter.wait(Bucket=bucket, Key=key)

        response = s3r.Bucket(bucket).Object(key)

        # Read the raw text file into a Email Object
        msg = email.message_from_string(response.get()["Body"].read())

        if len(msg.get_payload()) == 2:

            # Create directory for XML files (makes debugging easier)
            if os.path.isdir(TMP_DIR) == False:
                os.mkdir(TMP_DIR)

            # The first attachment
            attachment = msg.get_payload()[1]

            # Extract the attachment into /tmp/output
            extract_attachment(attachment)

            # Upload the XML files to S3
            upload_resulting_files_to_s3()

        else:
            print("Could not see file/attachment.")

        return 0
    except Exception as e:
        print(e)
        print('Error getting object {} from bucket {}. Make sure they exist '
              'and your bucket is in the same region as this '
              'function.'.format(key, bucket))
        raise e


def extract_attachment(attachment):
    # Process filename.zip attachments
    print("attachment.get_content_type" + attachment.get_content_type())
    content_type = attachment.get_content_type()
    file_name = attachment.get_filename()

    if "gzip" in content_type or "gzip" in file_name:
        contentdisp = string.split(attachment.get('Content-Disposition'), '=')
        fname = contentdisp[1].replace('\"', '')
        open('/tmp/' + contentdisp[1], 'wb').write(attachment.get_payload(decode=True))
        # This assumes we have filename.xml.gz, if we get this wrong, we will just
        # ignore the report
        xmlname = fname[:-3]
        open(TMP_DIR + xmlname, 'wb').write(gzip.open('/tmp/' + contentdisp[1], 'rb').read())

    # Process filename.xml.gz attachments (Providers not complying to standards)
    elif "zip" in content_type or "zip" in file_name:
        open('/tmp/attachment.zip', 'wb').write(attachment.get_payload(decode=True))
        with zipfile.ZipFile('/tmp/attachment.zip', "r") as z:
            z.extractall(TMP_DIR)

    else:
        print('Skipping ' + attachment.get_content_type())


def upload_resulting_files_to_s3():
    # Put all XML back into S3 (Covers non-compliant cases if a ZIP contains multiple results)
    for fileName in os.listdir(TMP_DIR):
        if fileName.endswith(".xml"):
            print("Uploading: " + fileName)  # File name to upload
            s3r.meta.client.upload_file(TMP_DIR + '/' + fileName, OUTPUT_BUCKET_NAME, OUTPUT_BUCKET_PREFIX + fileName)
