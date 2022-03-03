# Personal backup to Amazon S3

Script to easily backup personal files to Amazon S3 paying only $3.70 per TB per month.

See the [blog post](https://betterdev.blog/personal-backup-to-amazon-s3/)
for the full context and explanation.

## Usage

**Attention!** Usage will incur S3 usage charges.  
With default parameters, used storage class is GLACIER,
with objects billed for storage for 90 days minimum.

### Requirements

- [rclone](https://rclone.org/)
- [GNU Parallel](https://www.gnu.org/software/parallel/)

Install with Homebrew:

```bash
brew install rclone parallel
```

### Provision AWS resources

Deploy CloudFormation stack with the S3 bucket and IAM user:

```bash
aws cloudformation deploy --stack-name backupToS3 --template-file stack.yml --capabilities CAPABILITY_IAM
```

Get the bucket name and IAM user name from the CloudFormation Outputs in AWS Console.

Go to the IAM, open that user details, and create an access key in the "Security credentials" tab.

### Setup rclone

Configure rclone by running `rclone config`
or manually editing configuration file (`~/.config/rclone/rclone.conf`):

```ini
[backup]
type = s3
provider = aws
env_auth = false
access_key_id = xxxxxx
secret_access_key = xxxxxx
acl = private
region = eu-west-1
```

Provide generated IAM user credentials for `access_key_id` and `secret_access_key`.

## Run script

To backup directory as a single archive:

```bash
./backup.sh --bucket backuptos3-backupbucket-xxxxxxxxxxxxx --name my_disk --path /mnt/disk0
```

To backup each subdirectory as a separate archive:

```bash
./backup.sh --bucket backuptos3-backupbucket-xxxxxxxxxxxxx --name my_disk --path /mnt/disk0 --split-depth 1
```

Use `./backup.sh --help` for more info.
